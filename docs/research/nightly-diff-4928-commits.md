# Nightly 4928 commit coverage

Every commit from `git log --no-merges v0.1.4-nightly.20261028.3824..v0.1.11-nightly.20261119.4928 -- apps/web/src packages/client-runtime packages/shared`, 1683 in all. packages/contracts and the server belong to the wire audit, so this list leaves them out unless a commit also touched the client. The main doc, [nightly-diff-4928.md](nightly-diff-4928.md), describes each port group and the CandyWrapper files it touches.

Statuses:

- `port` means the change applies to CandyWrapper and nobody has checked whether CW already has it. The agent who takes the group checks CW first and writes `already in CandyWrapper` with the CW file when it finds the behavior there.
- `free with the runtime` means the server computes the result and CW shows what it gets.
- `n/a` means a test, refactor, React or web-only performance work, a server-only change, or a platform CW doesn't run on.
- `skip` gives its reason, usually a surface CW leaves to a native component, such as SwiftTerm or AppKit's IME handling, or a feature the user hasn't asked for.

Counts: 1167 port, 2 free with the runtime, 444 n/a, 70 skip. No commit reached `already in CandyWrapper` in this pass. The area column comes from a keyword match on the subject and the files the commit touched, so treat it as a hint.

## Port group boring-sidebar (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 5211acfe95 | #26463 | sidebar | feat(web): boring sidebar can show folder threads on two lines | ported (composer-5): Labs "Two-line folder rows" (`boringSidebarMultilineRows`, client setting, shown while Boring sidebar is on) puts folder threads on two lines, 54pt with the meta line (worktree glyph and branch or scratch machine, terminal, PR, issue, machine and agents) and 36pt without, the trailing icons then on the title line. Folder row titles now take the card colors. Spec sidebar-folder-rows (0.96 to 2.44%). Settings search catalog entry left to the settings agent |
| 911212bf4f | #26495 | composer | fix(web): open project picker from boring sidebar's header | already in CandyWrapper: App/Sources/PaletteCommands.swift:916 opens the picker in every sidebar |

## Port group composer-lists (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| fec83a18e3 | #17138 | composer | fix(web): numbered composer lists nest and lift correctly | ported: ComposerListContinuation follows 4928: Tab nests at the parent content column numbered after existing children, an empty nested item lifts one level per Enter, in source and rich mode |

## Port group diff-review (3)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| a5448f4c50 | #26730 | pr/git | fix(web): pull request diff follows the file tree, with a hide-tests filter | ported (panels-3): the PR Code tab follows the file tree order, and the Diff panel and Code tab hide tests behind a flask toggle with "N test files hidden", ChangedFileKind.swift, DiffPanelView, PullRequestCodeView; no spec case yet for the toggle |
| 5ef56853ef | #19941 | pr/git | feat(web): review local commits in the Diff pane | left (panels-2): reviewing local commits needs the A23 wire (`review.getBranchCommits`, source kind `commit`) and a commit scope in DiffPanelView |
| 348009de22 | #29083 | pr/git | fix(prs): include Storybook files in the test filter and counts | ported (panels-3): Storybook `.stories.` files count as tests, ChangedFileKind |

## Port group provider-fallback (3)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 861a51a6c4 | #26164 | usage | feat(server,web,mobile): fall back when the default provider is out of usage | ported, composer and store side: a new draft without its own pick starts on the server's `fallbackModelSelection` while its default provider is out of usage for its model (T3Store UsageFallback, ComposerSelectionStore.resolve), and the draft shows "Using <model>" with "<provider> is out of usage · resets <time>", "Use <default>" and a dismiss per window (ComposerController `updateFallbackBanner`, ThreadPanelView slot). Left for the Settings agent: the Fallback model row in Settings > Project defaults that writes `fallbackModelSelection`; the Settings row is ported (settings-2) |
| cb1de7ba23 | #27593 | settings | fix(web): configure reasoning for the fallback model | ported (settings-2): Settings > New threads > Fallback model, with the effort picker once a fallback is set (GeneralSettingsView.swift newThreadsSection, SettingsModelPickerControl `unsetFrom`) |
| bc448b8697 | #27859 | composer | fix(web): composer fallback keeps the effort of a model saved under an alias | ported with #26164: the fallback starts with its saved options as they are, so an effort saved under a model alias stays (ComposerSelectionStore.resolve) |

## Port group usage-meter (3)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 310c128552 | #26859 | usage | feat(web): Labs toggle keeps 5h, weekly, and context limits in view | ported (settings-4928): the retired Labs flag threadDetailsUsageEnabled still defaults Usage and Context on |
| 961026c6c9 | #27892 | usage | feat(web): context meter fills up and shows tokens against the limit | ported (settings-4928): the card's Context window row fills, shows tokens against the limit and ticks the auto-compact point |
| 669e2ea8e7 | #38789 | usage | feat(web): usage limit rows show your pace and open the usage page | ported (settings-4928): usage limit rows show room left, the time-left tick, the pace and reset in the tooltip, and open the Usage page |

## Port group sidebar-undo (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 35b298a159 | #26874 | sidebar | fix(web): undo notice moves to the sidebar footer so it never covers a thread | ported 9a0153d1 |

## Port group thread-details-card (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| d7935f135f | #26904 | thread | feat(web): choose what the thread details card shows | ported (settings-4928): Appearance's Thread details row and the card's right-click menu choose the items, the card hides them, Usage limits and Context window are sections, and an empty card offers Choose what to show. Side chats has no card section yet |

## Port group thread-load (4)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 7f39a860d9 | #27110 | thread | perf: huge checkpoints ship up to 75x smaller to clients | already in CandyWrapper: server side; TurnItem.filesTotal reads the cap (connection, protocol.md) |
| f702f892ae | #27722 | thread | fix(client): a new thread's content no longer stays blank after an early 404 | port |
| 5f8294246c | #24417 | thread | fix(client): reveal earlier agent turns in one load | port |
| 2482b03a01 | #35071 | connections | perf(client): threads load while the socket connects, with fewer round trips | already in CandyWrapper: ShellSession.startEarlyShellLoad and the HTTP bounded snapshot (connection) |

## Port group message-shapes (7)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| cba30591f9 | #26769 | thread | fix(web,mobile): image-only messages show the image, not the placeholder prompt | ported in 46e99443: the attachment-only prompt stays hidden (T3Store/UserMessagePresentation.swift, ThreadMinimapView.swift) |
| f012fa210d | #27305 | thread | fix(web): back-to-back messages from you stack as one burst with a single steer label | ported in 46e99443 |
| b8397e5caf | #27306 | thread | feat(web): images and videos sent with text sit above the bubble as their own shape | ported in 11fea921 |
| 1da41f9499 | #27324 | thread | feat(web): files sent without text show as file cards | ported in 11fea921 |
| e57ae5a0bf | #27377 | composer | feat(web): pasted text, voice notes, snapshots and sending files get their own shapes | ported in 11fea921: "Pasted text", "Sending…" on cards and the bare voice note. Skipped: the dedicated voice-note bubble style |
| 6fc9144a60 | #27383 | thread | fix: image-only messages no longer leak the attachment placeholder | ported in 46e99443: bubble and minimap. The search-index and title changes are server-side, so n/a |
| d6d2433609 | #27978 | thread | fix(web): back-to-back messages stack tight with joined corners | ported in 46e99443 |

## Port group model-picker (13)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| cfe28f0646 | #26881 | composer | fix(web): model picker opens at its final height instead of shrinking | ported: the docked picker opens at one fixed 346pt height (ModelPickerView `docked`) |
| c96c1b69f5 | #28057 | composer | feat(web): pick the model and its effort from one control | ported: Features/Pickers/ComposerModelEffort.swift, ComposerPickers.swift |
| 85bd3f2a2a | #28044 | composer | fix(web): hide Ultrathink from the Claude effort picker | ported: the effort column drops prompt-injected levels (`ComposerEffortControls.choices`) |
| 2359643cff | #28076 | composer | fix(web): model picker stays open until dismissed, with a Show more row | ported: the docked picker stays open after a pick, Show more trails the list (T3Store ModelPickerSections) |
| 15fe283272 | #28162 | composer | fix(web): effort picker shows Default or the checkmark, flush right | ported: ComposerEffortRowView shows Default or the check, flush right |
| 5fe18d79ac | #28307 | composer | fix(web): keep the model picker in place when its label changes | ported: the docked picker aligns to the trigger's end edge |
| 575579d68a | #28409 | composer | fix(web): model picker stays put with long names and agent options | ported: 224pt model name cap, fixed height, other options open beside the column |
| 77a728e3a1 | #28005 | connections | fix(web): show mixed automatic defaults across environments | ported (settings-2): the Model row compares each target's effective default and reads "Automatic (mixed)" with T3's status lines (GeneralSettingsView.swift `effectiveDefaultsDiffer`) |
| 72f05f6d8e | #29017 | composer | fix(web): model picker uses the full window height in short windows | ported: PopupPlacement `collision: .shift` keeps the docked picker on top and offers the whole window height (ComposerPickers.swift) |
| 42cf5a168c | #26415 | composer | fix(web): compact model picker row indicators | ported: one-line model rows with the provider logo (ModelRowView `layoutModern`) |
| 2d0efd3584 | #27034 | composer | feat(claude): Ultracode works with any effort, like Claude Desktop | ported: the footer's Ultracode toggle and the trigger's workflow icon; the server sends the descriptor |
| 402d0623d5 | #31739 | thread | fix(composer): persist model picks before the next message | ported: a pick on a started thread sends `thread.model-selection.set` at once (ComposerController `applyThreadModelPick`, T3Store `modelPickToApply`) |
| d0f7a509cc | #33511 | composer | feat(models): the model picker checks for new models when it opens | ported: an opened model picker sends `server.refreshProviders {modelCatalogOnly: true}` when the server has `modelCatalogRefresh` (ComposerPickers `onModelPickerOpen`, ComposerController) |

## Port group sidebar-shelves (3)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 503bf77668 | #25384 | sidebar | fix(web): prevent sidebar shelf animations from overlapping headers | ported 9a0153d1 |
| 955e2bfbb5 | #28515 | thread | fix(clients): questions always move a thread out of Working | ported 9a0153d1; the side chat roll-up waits for side chats |
| 34701646e3 | #31269 | sidebar | revert(web): working threads stay in the Working shelf when their environment disconnects | no net change: reverts #26195, which CandyWrapper never had |

## Port group files-preview (19)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| c018660572 | #27497 | files | fix(shared): preserve surrogate pairs in truncated CSV cells | ported (panels-2): a truncated cell never splits a surrogate pair, DelimitedTable.parse |
| f5fe0790e7 | #31868 | pr/git | fix(web): Office previews say "1 page", "1 sheet", "1 slide" and "1 row" | waits on the 3814 preview task in PROGRESS.md: CandyWrapper hands this file type to Quick Look (NativeFilePreviewView), so T3's own renderer fix has nothing to land on |
| bc3eb6d2b2 | #29051 | files | fix(web): fix japanese text in file viewer not rendering | left (panels-2): not checked against CodeFileView's text decoding |
| 84478e09c1 | #34331 | files | fix(web): long merged spreadsheet selections no longer crash | waits on the 3814 preview task in PROGRESS.md: CandyWrapper hands this file type to Quick Look (NativeFilePreviewView), so T3's own renderer fix has nothing to land on |
| 787c59c802 | #32040 | pr/git | fix(web): Word previews no longer cut ordinary documents short | waits on the 3814 preview task in PROGRESS.md: CandyWrapper hands this file type to Quick Look (NativeFilePreviewView), so T3's own renderer fix has nothing to land on |
| c8e8b58ee6 | #34429 | pr/git | fix(web): improve Excel spreadsheet previews | waits on the 3814 preview task in PROGRESS.md: CandyWrapper hands this file type to Quick Look (NativeFilePreviewView), so T3's own renderer fix has nothing to land on |
| 6464729c56 | #34453 | files | fix(web): improve PowerPoint slide font rendering | waits on the 3814 preview task in PROGRESS.md: CandyWrapper hands this file type to Quick Look (NativeFilePreviewView), so T3's own renderer fix has nothing to land on |
| 4574c6013d | #36602 | files | fix(web): preserve saved notebook traceback frame boundaries | waits on the 3814 preview task in PROGRESS.md: CandyWrapper hands this file type to Quick Look (NativeFilePreviewView), so T3's own renderer fix has nothing to land on |
| d6244ac5a3 | #36595 | files | fix(web): preserve literal entities in EPUB CDATA | waits on the 3814 preview task in PROGRESS.md: CandyWrapper hands this file type to Quick Look (NativeFilePreviewView), so T3's own renderer fix has nothing to land on |
| 6effe74c59 | #36689 | pr/git | fix(web): show repeated table rows and cells in ODT previews | waits on the 3814 preview task in PROGRESS.md: CandyWrapper hands this file type to Quick Look (NativeFilePreviewView), so T3's own renderer fix has nothing to land on |
| 13a6782a6c | #36685 | files | fix(web): ODS time cells without display text show their value | waits on the 3814 preview task in PROGRESS.md: CandyWrapper hands this file type to Quick Look (NativeFilePreviewView), so T3's own renderer fix has nothing to land on |
| 0fdc99c870 | #36703 | pr/git | fix(web): notebook previews strip ANSI colors from saved tracebacks | waits on the 3814 preview task in PROGRESS.md: CandyWrapper hands this file type to Quick Look (NativeFilePreviewView), so T3's own renderer fix has nothing to land on |
| 10a44f5553 | #36767 | pr/git | fix(web): RTF previews keep named spaces, hyphens and joiners | waits on the 3814 preview task in PROGRESS.md: CandyWrapper hands this file type to Quick Look (NativeFilePreviewView), so T3's own renderer fix has nothing to land on |
| 776698a3e7 | #33294 | pr/git | fix(web): OpenDocument slide previews no longer print speaker notes | waits on the 3814 preview task in PROGRESS.md: CandyWrapper hands this file type to Quick Look (NativeFilePreviewView), so T3's own renderer fix has nothing to land on |
| 85e009fbc9 | #34329 | pr/git | fix(web): show TAR hard links in archive previews | waits on the 3814 preview task in PROGRESS.md: CandyWrapper hands this file type to Quick Look (NativeFilePreviewView), so T3's own renderer fix has nothing to land on |
| 8ab40cc88e | #31885 | pr/git | fix(web): the PDF preview says "1 / 1 page" for a one-page PDF | n/a (panels-2): PDFs show in Quick Look, which draws its own page count |
| 2370e338f7 | #31886 | pr/git | fix(web): the SQLite, archive and notebook previews say "1 row", "1 entry" and "1 cell" | waits on the 3814 preview task in PROGRESS.md: CandyWrapper hands this file type to Quick Look (NativeFilePreviewView), so T3's own renderer fix has nothing to land on |
| dde53b11f3 | #31929 | terminal | fix(web): notebook error previews no longer show terminal color codes | waits on the 3814 preview task in PROGRESS.md: CandyWrapper hands this file type to Quick Look (NativeFilePreviewView), so T3's own renderer fix has nothing to land on |
| d085ee5d15 | #38188 | pr/git | fix(web): decode HEIC previews under desktop CSP | waits on the 3814 preview task in PROGRESS.md: CandyWrapper hands this file type to Quick Look (NativeFilePreviewView), so T3's own renderer fix has nothing to land on |

## Port group thread-media (5)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 854247e242 | #27519 | thread | fix(web): expanded SVG diagrams fill the image viewer | left (thread-3): ExpandedImagePreviewView is Features/Composer, another agent's area; needs the SVG mime type passed and no upper zoom cap for vectors |
| a4b6afe184 | #27440 | thread | fix(client-runtime): threads with many images no longer flood a remote with URL requests | ported (thread-3): AssetURLLimit, 6 assets.createUrl at a time |
| e0f69e9ea4 | #29741 | thread | fix(web,mobile): chat images reload when the agent rewrites the file | left (thread-3): needs the thread's workspace mutation id (client-runtime state/assets.ts, threadDetail.ts at 4928) in MarkdownImageSource's key so a rewritten file signs a new URL |
| a11ad7424d |  | thread | fix(web): show app bundle icons and open apps from markdown links | left (thread-3): app bundle icons need the server's NativeAppIconResolver asset and an app-icon chip in FileLinks; open goes through externalLauncher |
| 330b9f4840 | #34333 | thread | fix(web): arrow keys and buttons step through the images an agent viewed | ported in 2eb8794e |

## Port group scheduled-tasks (4)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 4ac97be2b6 | #28104 | settings | feat(scheduler): run a scheduled task once at a specific date and time | ported (settings-4928): Once with a calendar date and a time field |
| 4aab23cd72 | #30326 | settings | feat: scheduled tasks can run in one thread with a fresh session each run | ported (settings-4928): Destination mode select and notes, threadMode sent behind scheduledTaskThreadModes |
| 4a087861d0 | #31764 | settings | feat(scheduled-tasks): tasks link to their thread | ported (settings-4928): bound tasks link to their thread from the row |
| 8e6a732305 | #31379 | settings | feat(web,mobile): move a scheduled task to another thread | ported (settings-4928): Destination thread menu, move and unbind rules; no thread search yet |

## Port group subagent-approvals (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 70f475f511 | #28516 | thread | feat(clients): surface child approvals in parent threads | ported (thread-3): ChildApprovalsView above the composer, a watch per approving child in ThreadLineageController, ChildApprovalsFidelityTests 1.78 to 2.74% |

## Port group usage-page (5)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| e6e2ab05cc | #28952 | usage | feat(usage): filter Usage totals by provider and model | ported (panels-2): each summary read sends the environment's `usageModelFilter` server setting as `modelFilter`, UsageController |
| 9e1f81c788 | #34106 | thread | feat(claude): Fable resets are offered and redeemed apart from weekly resets | ported (panels-4): Fable and weekly resets get a row and a Use button each, and the confirm names the choice (UsageResetCredits.Option, UsageLimitsLogic.resetChoices, UsageResetCreditsView, the Usage segment popover; packages/shared/src/usageLimits.ts, UsageLimits.tsx:364-387) |
| 0b21a82aa3 | #35427 | usage | fix(shared): pooled limits weight each account by its plan size | left (panels-2): pooled limits weighting, not checked |
| 63d5c6dfe4 | #34146 | usage | feat(opencode): read usage limits from the connected server | left (panels-2): not checked |
| 7fab4ef978 | #33993 | usage | perf(usage): the Usage page shows cost and tokens at once instead of after a full scan | ported (panels-2): with nothing shown, the first read is `provisional`, then the plain read, then the awaiting one, UsageController.fetchProvisional |

## Port group timeline-handoff (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| c65f8d552b | #28995 | composer | feat(chat): threads show when you switch models or effort | ported in c06c69e7 |

## Port group timeline-misc (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| ab8e488e10 | #28629 | thread | feat(antigravity): runtime 1.4.5 with real turn failures and subagent work | port; Antigravity turn failures, server side mostly |
| ddc3cefbc4 | #34177 | thread | fix(clients): collapsed turns show one context-compacted divider | port |

## Port group notifications (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| a852de0b7b | #29146 | thread | fix(web): play completion sounds without delay | ported (panels-2): completions notify at once; only a background progress wake's completion waits 5 s, ThreadNotificationTracker |
| 5ef603df34 | #36527 | pr/git | fix(web): remove routine success notifications | ported in part (panels-2): pull request copies, the Pull Requests page link copy, Git branch copies and the diff path copy toast only on failure. Left: the same in Sidebar, Settings, chat, media and the thread action menu, which other agents hold |

## Port group provider-status (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| e27e12d9b4 | #24861 | settings | feat(web): add refresh to provider status banners | ported: the provider status banner ends with an outline Refresh after the setup link, "Refreshing..." while `server.refreshProviders {instanceId, refreshModels}` runs (ThreadErrorBannerView, ComposerController) |

## Port group composer-context-strip (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 3d369d5596 | #30275 | composer | feat(web): open full access menu from the new thread context strip | ported: the new-thread strip's permissions control opens the access menu above itself (ComposerPickers `openPermissions`) |

## Port group copy-thread-link (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 251369d31c | #26290 | connections | feat(server,web,mobile,desktop): Copy thread copies a link that opens the thread | port; needs wire: thread deep link |

## Port group connection (8)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 8ab024f31a | #31071 | thread | fix(client-runtime): a thread keeps syncing after a stream defect | port |
| b9522c845b | #23758 | connections | fix(client): a big server config on a slow link no longer drops the connection in a loop | port |
| 6c7d23dcfc | #29264 | connections | fix(client-runtime): slow SSH runtime downloads report their own error, not a setup timeout | port |
| 8851e307d8 | #24309 | connections | fix(client-runtime): slow foreground probes keep live sessions connected | port |
| 962eeefa03 | #24761 | thread | fix(client-runtime): retry messages after socket loss with the same command ID | port |
| de21fbcff3 | #25919 | thread | fix(client): a thread whose subscription dies on a defect resubscribes instead of staying blank | port |
| 7c22095fcc | #34623 | connections | fix(client-runtime): a stalled sign-in token or dead route no longer holds a reconnect for 40 seconds | port |
| e396bb2e26 | #37990 | device | feat(client-runtime): direct links pair with the device key and renew themselves | left (settings-2): T3Client/Connect work (direct links pair with the DPoP device key and renew); another agent held T3Client's connection code this session |

## Port group composer-markdown (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| af54fe2344 | #30421 | thread | fix(web): make styled composer Markdown markers editable | left (not reached in composer-3): 4928 reveals a styled range's Markdown as editable text while the caret is in it (composer-markdown-source.ts, 593 lines); CW keeps markers beside the styled words |

## Port group snooze-requests (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| e66c3168a4 | #20058 | thread | fix(threads): allow snoozing pending input requests | left: the snooze rule lives in threadSettled.ts (`pendingUserInputAt`, a snoozed question wakes only for a newer one); it belongs with the sidebar snooze logic in T3Store |

## Port group clear-command (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 99e361e415 | #30325 | composer | feat: /clear starts a fresh session in the same thread | ported: `/clear` (menu or typed alone) arms a fresh session on servers with `freshContext`, shows "Your next message starts a fresh session" with Keep the current session, and the next send carries `freshContext: true`, never steering or compacting first. The fresh-session timeline row is left for the thread agent |

## Port group pr-actions (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| e1494ae25b | #25761 | thread | perf(pr): actions update every client from the host's reply instead of re-reads | ported (panels-2): `runAction` asks `replyWithSummary` and the panel shows the reply without a re-read unless it reopened or moved the head; App/Sources/PullRequestsController.swift run(), T3Protocol PullRequestSummary |
| d5a50a1d0d | #32774 | pr/git | perf(pr): actions, title edits and labels show the moment you click, on every host | left (panels-2): optimistic title, label and state edits on every host; the action reply patch (#25761) is in, the instant local edit is not |

## Port group pr-composer (3)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 7bc2a40ced | #30747 | pr/git | feat(pull-requests): PR composers complete @user mentions | ported (panels-5): @login completion in every PR textarea over `pullRequests.filterOptions` authors, PullRequestCompletion.swift, gated on `capabilities.mentions` |
| f08d8dd0a5 | #30579 | pr/git | feat(web): add pull request comments to the chat | left (panels-2): add a PR comment to the chat, needs the composer's context insertion from Features/Composer |
| e4ff5da0d3 | #30857 | pr/git | feat(pull-requests): PR composers complete #123 and GitLab !123 references | ported (panels-5): #123 and !123 completion with `references` and `sigil`, gated on `capabilities.referenceSigils` |

## Port group pi (4)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 0d266fbe52 | #23901 | thread | feat(pi): show extension status in existing controls | port; Pi extension status |
| eeb6e23675 | #27397 | composer | fix(web): keep Pi thinking controls visible before selection | port |
| 225685a8d5 | #33177 | composer | feat(pi): Fast and Ultrafast service tiers for Pi models | port |
| 871b00907d | #33982 | thread | fix(pi): a steer Pi has not read yet shows as waiting, not steered | port |

## Port group command-output (4)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| a7f6c68fe9 | #21542 | terminal | fix(shared): underline styles and colours no longer scramble command output colours | skip: CandyWrapper draws command output as plain text and drops SGR colors (T3Store/CommandOutputBuffer.swift), so there is no color parser to fix |
| f315da3339 | #24042 | terminal | fix(shared): PASS and FAIL badges stay readable in dark command output | skip: same as #21542, command output has no colors in CandyWrapper |
| 2bee33eb19 | #34332 | terminal | fix(shared): preserve Unicode during command output overwrites | ported in 5ed8c36a |
| eb90b79217 | #38946 | thread | fix(client-runtime): command rows unwrap Windows pwsh -Command and cmd /c launchers | ported in 5ed8c36a |

## Port group auto-settle (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| d4247a5a19 | #32325 | settings | feat: auto-settle inactive threads after 7 days by default | ported 9a0153d1 |

## Port group settings-providers (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 1b952135a1 | #29280 | settings | fix(providers): remove incomplete ChatGPT connections | port |
| 315b06c5ec | #21249 | settings | feat(providers): managed Antigravity and Codex installs can update past their pin | port |

## Port group archive-delete (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| c864b1c1e1 | #22160 | sidebar | feat(web): delete archived threads from the archive page | already in CandyWrapper: Features/Settings/ArchiveSettingsView.swift:185 deletes archived threads |

## Port group questions (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| f016a16b39 | #19659 | thread | fix(acp): preserve native form questions and typed answers | already in CandyWrapper: the client half keeps `__proto__` question ids as own drafts, which Swift dictionaries do anyway (T3Store UserInputAnswers); the rest is the ACP server |

## Port group agent-signin (4)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 917ce994e4 | #32186 | thread | fix(web): agent sign-in defaults to Auto access | skipped: the agent sign-in page (ConnectAgentSurface) is T3's web route /connect-agent, opened in a browser; CandyWrapper has no copy of it |
| dd0737d3e2 | #33600 | connections | feat: approve agent sign-ins with T3 Connect instead of a code | skipped: /approve-agent and /connect-agent are T3 web routes the agent opens in a browser; CandyWrapper has no agent sign-in pages |
| 9a0d02723c | #33632 | connections | feat: approve agent sign-ins on app.t3.codes with T3 Connect | skipped: hosted approval changes T3's web sign-in pages and the Use in another app wizard, which CandyWrapper doesn't have |
| eb381a7d4f | #33645 | thread | fix: hosted agent approval no longer fails with "Your session cannot approve" | skipped: fixes the hosted approval web page, which CandyWrapper doesn't have |

## Port group palette-search (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 09a54f01bc | #32242 | files | fix(search): keep whole-word title matches above busy prefixes | port |

## Port group thread-links (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 23e3465ec6 | #32830 | thread | fix(clients): unloaded thread links show their title and project icon | ported: a thread chip this client hasn't loaded asks `orchestration.getThreadLinkMetadata` once where the server sets `threadLinkMetadata`, then shows the title and project icon (thread-2, App ThreadSession `linkMetadataThread`) |
| f558007b20 | #30709 | thread | fix(clients): parse angle-bracketed thread link destinations | port |

## Port group labs-cleanup (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 521ac7c218 | #33131 | settings | feat(settings): clean up Labs: promote tool calls, remove plan mode and old toggles | ported: Labs drops Legacy features, the composer drops Build/Plan, /plan and /default, Tool calls in chat sits in Chat > Activity; the dead proposed-plan follow-up in ComposerController and T3Store's `planModeEnabled` context field are left for cleanup |

## Port group secret-cards (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 3bb4544f90 | #33157 | thread | fix: secret cards show the agent's sign-in link as a button | port |

## Port group welcome-page (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 4f0b74e190 | #33209 | settings | feat(web): first run is one Welcome page instead of a 3-step wizard | ported (settings-3): Features/Settings WelcomePageView, WelcomePageModel and WelcomePageLogic; 27-welcome 0.62% |

## Port group send-while-uploading (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| ad9e87111f | #33092 | thread | feat(web): send messages while attachments upload | ported: Send stays enabled while uploads run and the send goes once they land; approval redirects still wait (ComposerAttachmentRules `sendBlockReason`). In a thread the message now shows at once with files reading "Sending…", the composer clears, and the dispatch waits for each upload, whose outcome outlives the draft; a failed upload takes the message back and restores the draft (thread-2, ComposerController `sendingUploads`). Left: a new thread's first send still waits in the composer |

## Port group design-icons (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| f86e21f7cc | #25422 | pr/git | fix(web,mobile): replace sparkles icons and ban them with a lint rule | port; sparkles icons replaced |

## Port group linked-envs (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 92f1b8ec25 | #34139 | settings | fix(peer): link requests use the addresses the app already has for a machine | port |
| f991781872 | #34721 | thread | fix(server,web,mobile): messages from a linked environment name the thread that sent them | port |

## Port group accessibility (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 40c3682543 | #33900 | thread | feat(web): screen readers can hear the agent's messages and steps during a turn | left (panels-2): ThreadActivityAnnouncer belongs in Features/Thread TimelineView, which another agent holds |

## Port group html-render (5)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 5bb5d53312 | #22349 | thread | fix(web): full-screen HTML pages fit their content and zoom by reflowing | left (thread-3): the full-screen HTML dialog's fit and reflow zoom (HtmlRenderDialog.tsx at 4928) in HtmlRenderDialogView; needs an on-screen check |
| 860fa7c7b6 | #34344 | thread | fix(shared): keep HTML bootstrap outside quoted attributes | free with the runtime: the server injects the bootstrap (apps/server/src/htmlRender/HtmlRender.ts:490) |
| 25123c28d4 | #35022 | thread | fix(shared): html_render pages from OpenCode 2 Code Mode show and are cleaned up | ported in d1f3d2fc |
| ddd02848e6 | #35434 | thread | fix(shared): html_render pages show for Grok threads | ported in d1f3d2fc |
| 4ab3b98411 | #32129 | thread | fix(shared): MCP apps that fall back to a blob: frame no longer render blank | free with the runtime: the server writes the MCP app CSP (apps/server/src/mcpApps/McpAppSnapshot.ts:82) |

## Port group markdown-callouts (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 2c74ea6915 | #22239 | thread | fix(web): render Claude insight blocks as a callout | ported in eceea265 |
| 1a8ecc64b7 | #34181 | thread | feat(web): a quote in a sent message shows as an inset card | ported in 4bb35432 |

## Port group server-updates (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| a74ee4cc7c | #27275 | connections | fix(client-runtime): server updates stop waiting 32 minutes when the host returns without this update's outcome | ported (settings-3): ServerUpdater reads the accepting process ready.at before a launcher update; another process ends the wait, and only this update outcome counts (ServerUpdate.swift matchesResume, failure) |
| 5958d00ede | #35346 | settings | perf(web): Update everything downloads a server's update while providers install | ported (settings-3): Update everything stages each server with stageOnly while providers install, only on servers with serverUpdateStaging (ServerUpdates.stage) |

## Port group rewind (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 31eea883c7 | #18379 | thread | fix(rewind): allow conversation-only rewind in non-git workspaces | port; needs wire: conversation-only rewind |

## Port group timeline-steer (3)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 5ee7f6fee8 | #23249 | thread | fix(chat): show late async answers in their own runs | ported in f200f135 |
| 836b86a5d6 | #34501 | thread | fix(chat): keep final replies visible after steering | ported in 082f60cb, without the deferredWork ordinal skip and the Zen filter, which CW lacks |
| 9fb4492329 | #23420 | thread | fix(chat): requeued steers no longer look delivered | ported in d819c9ef: the client visibility and restore. The rest is server-side |

## Port group pr-review-threads (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| cf906e1fcf | #34644 | pr/git | feat(web): resolved review conversations fold into avatars on their diff line | ported (panels-3): a line's resolved conversations fold behind up to three author avatars at the line's right, a click or Space shows them, a conversation seen open stays; PullRequestResolvedThreadsButton, DiffAnnotationContent.lineOverlayWidth |

## Port group add-project (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| dc032d7c8f | #34978 | thread | feat(web,mobile): Add project lists only GitHub until you turn other hosts on | ported (panels-2): Add project lists the hosts `offeredSourceControlProviders` turns on, GitHub by default; a server without the setting keeps every host. The Settings switch belongs to the Settings agent |
| f419698aea | #35202 | sidebar | feat(web): drop folders on the sidebar to add them as projects | ported 9a0153d1; adds on the primary environment, see #38722 |

## Port group terminal (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| c9f0caca1b | #33942 | terminal | perf(server,client): attaching to a terminal with a large history over a slow link drops from 5,555 ms to 751 ms median (7.4x) | left (panels-2): terminal attach history paging needs wire |
| 93cbca3fcb | #36368 | terminal | fix(terminal): trimmed history no longer replays half of a control sequence | left (panels-2): trimmed history replaying half a control sequence, SwiftTerm side not checked |

## Port group resume (3)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 5f4368165b | #28810 | composer | fix(client): hide Resume while a pending request blocks continuing the run | ported in abe98edb |
| a34427662b | #27079 | terminal | fix(web): Enter on an empty prompt resumes an interrupted thread | ported in abe98edb |
| 442b1db161 | #35755 | composer | fix(web): Resume replaces Stop without a lingering Stopped button | ported in abe98edb |

## Port group history-swipe (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 5cbdf00481 | #30173 | thread | fix(web): mostly vertical trackpad scrolls no longer navigate back or forward | port |

## Port group connect-signin (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 1219f62845 | #23620 | connections | fix(web): T3 Connect sign-in offers Retry after Clerk fails to load | skip (settings-2): CandyWrapper loads no Clerk script; the native client reads the session from the Keychain, so there is no load to fail and retry |

## Port group pr-diff (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| f12e8206f5 | #37007 | pr/git | fix(web): load a too-large PR file's diff on demand | ported (panels-3): a withheld file shows "Diff too large to display." with Load diff, read alone with `path`, its header counts from `omittedFileStats`; PullRequestWithheldFileNotice, PullRequestsController.loadWithheld; a new head forgets the reads |

## Port group pr-prefetch (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 238678951a | #32842 | thread | perf(web): resting on a PR row also reads its activity, so the timeline shows on click | left (panels-2): hover prefetch of PR activity |
| 4b22bb47d4 | #32911 | pr/git | perf(pr): PR panel paints from saved data and reads ahead on intent | left (panels-2): PR panel paints from saved data and reads ahead on intent |

## Port group pr-links (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| b0f0c44d22 | #37703 | pr/git | fix(shared): open Forgejo and Gitea /pulls/ tab and commit links | left (panels-2): Forgejo and Gitea /pulls/ links, needs the change request URL parser in T3Protocol RepositoryIdentity+PullRequests |

## Port group keybindings-unassign (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| d27002bf99 | #28687 | settings | feat(web): unassign default keyboard shortcuts | ported (settings-4928): Unassign on default rows, the Unassigned button and note, conflicts and the restored condition |

## Port group browser (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 14d57b451e | #38865 | browser | fix(web): server browser pane reports when Chromium draws no frames | left (panels-2): the server browser pane's no-frames report |

## Port group connect-settings (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| a941ab544d | #37823 | connections | fix(connect): restrict relay configuration and token destinations | left (settings-2): T3Client/Connect relay allow list for configuration and token destinations; held for the T3Client owner |
| 6b45d90047 | #38892 | connections | fix(connect): let remote clients with relay configuration link | left (settings-2): with #37823, T3Client/Connect |

## New feature simlock (6)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| be6ff17f51 | #25259 | device | feat(devices): lease simulators and emulators from a Simlock pool (alpha) | skip: alpha simulator pool, new feature list |
| be7d86fa66 | #26706 | device | feat(devices): Simlock setup uses each machine's agent-device token, checks tokens, and lists the pool through worker reconnects | skip: alpha simulator pool |
| 812c0a71c7 | #26797 | device | feat(devices): support Android EAS Simulator sessions | skip: EAS simulator sessions, device alpha |
| d06ba27166 | #35994 | device | fix(device): Simlock viewer stops retrying an ended lease and keeps its reason | skip: Simlock viewer |
| 7bf7527a0a | #25121 | device | fix(devices): agents can test the mobile app on remote device hosts | skip: device hosts |
| 88c42f471b | #36951 | device | fix(devices): rename EAS Simulator to Expo Simulators | skip: EAS simulators rename |

## New feature noproject-to-project (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 58e60bf5e8 | #26767 | thread | feat: turn a No project thread into a project | ported (sidebar-2): projects.createFromThread behind threadProjectFromScratch; thread menu Turn into project with its toasts |
| 84e69da395 | #34788 | pr/git | fix(web): No project threads offer no Initialize Git, and their linked PRs show and act in the thread | left (composer-4, checked): nothing on the sidebar side; the commit changes ThreadDetailsPanel and ThreadDetailsPrRow(s) (Features/Thread), BranchToolbarBranchSelector (Features/Git) and PullRequestDetailPanel (Features/PullRequests) composer-5: rechecked, the reason holds (that area's agent is still working there). |

## New feature fleet-channel (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| f2943ee90e | #26288 | connections | feat(updates): switch your whole fleet between Stable and Nightly in one step | left (settings-3): wire ready (ServerNpmRelease, ServerUpdateLogic.input channel/targetDatabaseMigration); needs UpdateTrackSwitchDialog.tsx:43-227 as a native dialog, updateTrackSwitch.logic.ts and the Sparkle reinstall for this app |

## New feature secrets (10)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 7a4f5b6188 | #25709 | files | feat(settings): add and list 1Password secret providers behind T3CODE_FEATURE_SECRETS | skip: behind T3CODE_FEATURE_SECRETS |
| ee81ea4ce8 | #27044 | settings | fix(settings): servers check secret provider writes and keep unknown configs to themselves | skip: behind T3CODE_FEATURE_SECRETS |
| 97e35bcf23 | #27115 | settings | feat(settings): point provider environment variables at a secret provider | skip: secret providers |
| bd3cc5c228 | #27763 | device | feat(device): read the EAS access token from a secret provider | skip: secret providers |
| 4a94658ab4 | #31652 | settings | feat(settings): Simlock, Antigravity and OpenCode credentials can come from a secret provider | skip: secret providers |
| 7462b16f36 | #31670 | settings | feat(secrets): answer a secret request with a secret provider reference | skip: secret providers |
| 187781e9a0 | #31651 | settings | fix(settings): removing a secret provider clears the fields that used it | skip: secret providers |
| b690f08cbf | #31754 | settings | fix(web): removing a secret provider lists the Simlock tokens that read from it | skip: secret providers |
| ee9e36c8b2 | #31723 | settings | feat(secrets): check a secret reference before saving it | skip: secret providers |
| 6641231797 | #33585 | thread | fix(secrets): notify when a delegated agent asks for a secret | skip: secret requests from delegates |

## New feature star-prompt (4)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| d92c437baa | #27832 | files | feat(web): ask for a GitHub star once after 5 prompts | port |
| 5806afff67 | #28364 | files | fix(web): skip star prompt when the server check is unavailable | port |
| 5d3d78ab93 | #29922 | files | feat(web): ask for a GitHub star when idle, and star in one click | port |
| cefb544af3 | #29987 | files | feat(web): celebrate a GitHub star with confetti | port |

## New feature side-chats (19)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 50c1c5dc53 | #26901 | browser | feat: side chats beside the main thread | ported (side-chats, composer-4): the right panel's Side chat tab with its state dot, the + menu row behind `sideChats`, the pane's header with Bring back, Delete and Close over the side chat's embedded chat, the fork, mode and send sequence with the unused-thread cleanup, closing a never-run side chat deletes it, opening a side chat routes to its parent's tab. composer-4: the pane's composer is a second ComposerController on the panel's shared drafts, so attachments, chips, `/`, reply and drafts work there. Left: the details card's Side chats section (Features/Git) |
| b5c83cdb95 | #28326 | thread | Show the full title in lineage/side-chat row tooltips | left: planned in side-chats-4928.md (sidebar-2) |
| 171f78b879 | #29917 | thread | fix(client): project removal counts only listed threads, not side chats or subagents | already in CandyWrapper: SettingsPages.swift:80 counts only lineage.isListed threads (sidebar-2) |
| 12ec17ce4c | #29891 | thread | fix(web): opening a project from the command palette no longer lands in a subagent or side chat | already in CandyWrapper: PaletteCommands.swift:717 skips threads that are not listed (sidebar-2) |
| 725cfc9c3d | #31114 | thread | fix(threads): side chats inherit parent permissions by default | ported (side-chats): the start copies the parent composer's permission mode with thread.runtime-mode.set |
| e455200077 | #32315 | thread | fix: side chats start with the parent's permission mode and reasoning level | ported (side-chats): mode and the parent composer's model selection, reasoning included, go with the first message |
| 915676ee6a | #30370 | thread | fix(web): deleting the open thread no longer opens a side chat or subagent | already in CandyWrapper: the delete fallback skips threads that are not lineage.isListed (sidebar-2) |
| b8c2cfad6b | #29832 | composer | fix(web): deleting a thread clears its side chats' drafts | left: planned in side-chats-4928.md (sidebar-2) |
| b10cdded50 | #32929 | thread | fix(web): a new side chat focuses its message input | ported (side-chats): SideChatController.start focuses the pane's composer |
| 46015ec958 | #33160 | thread | fix(web): Go to source on a side chat quote keeps you on its parent thread | left: planned in side-chats-4928.md (sidebar-2) |
| d63db06436 | #34686 | pr/git | fix(contracts): side chats open after an abandoned worktree setup | left: planned in side-chats-4928.md (sidebar-2) |
| 76ae36ef8c | #36800 | pr/git | fix(web): deleting a thread with side chats offers to delete its worktree | left: planned in side-chats-4928.md (sidebar-2) |
| 2dd810d0f6 | #36932 | thread | fix(web,mobile): /btw and /side drafts show the send arrow while a turn runs | left: needs the composer's primary button to read `/side` text while a turn runs |
| a31fab93a2 | #31360 | thread | fix(web): focus side-chat composer when selecting its tab | left: planned in side-chats-4928.md (sidebar-2) |
| d23f479a87 | #32117 | thread | fix(web): right panel shortcuts work while a side chat has focus | ported (composer-4): keys inside a side chat run its own composer table; of the chat's commands only rightPanel.toggle, close and toggleMaximized reach the main chat (useChatShortcuts.ts:26-30, 75-95); app commands still run |
| def3722faa | #31931 | thread | fix(web): Shift+F6 moves from a side chat back to the main chat | ported (composer-4): F6 and Shift+F6 (shared keybindings.ts:59-63) move between the main chat's and the side chat's composers; the full workspace-area cycle (workspaceFocus.ts) is not ported |
| 4fa5f0e0e6 | #32907 | thread | fix(web): a side chat's subagent opens its parent as a side chat tab, not a bare page | left: planned in side-chats-4928.md (sidebar-2) |
| 0de6ddb823 | #37228 | thread | fix(web): editing a queued message into /btw no longer saves it to the main thread | ported (side-chats): ComposerController.sendSideChat refuses in a queued edit with T3's toast |
| 052ca497cf | #38350 | composer | fix(web,mobile): side chats keep your attachments and context | ported (composer-4): `/side` carries the draft's attachments, chips and reply once uploads are ready (useComposerSend.ts:580-690); only an open question's answer asks to remove them |

## New feature pin-archive-projects (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| ffaa1dba76 | #26154 | sidebar | feat: pin favorite projects and archive old ones | ported (side-chats, composer-4): pinnedAt and archivedAt, pickable groups in the filter, draft picker and palette, pin buttons and Pin project in the filter, the project menu and the palette, pinned and archived folder order, unarchive on re-add. composer-4: the draft picker's pin buttons, Mod+Shift+P on a picker's highlighted row (DraftHeroHeadline.tsx:262-299, ProjectPinButton.tsx:11-55) and the shortcut in the pin's tooltip. Left: Project settings' Pin and Archive rows (Features/Settings) |

## New feature managed-policy (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| d897d3f3f0 | #27197 | settings | feat: managed policy for organization-wide T3 Code configuration | skip: org policy, enterprise |
| bd48d8c8f6 | #29862 | thread | feat(policy): admins set managed policy from a Group Policy template | skip: Windows Group Policy |

## New feature thread-tags (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 30654b3e91 | #29053 | pr/git | feat: tag threads and hide tagged threads while recording | ported in part: the sidebar hides tagged threads while the environment hides them; tagging UI and the palette, PR and notification filters are left |

## New feature ghq-clone (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 707dcdaa16 | #24904 | sidebar | feat: optionally clone repos into ghq-style <host>/<owner>/<repo> folders | left (panels-2): ghq-style clone folders need the clone layout setting and its wire |

## New feature dictation (20)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| a9a1b8c4be | #30623 | device | feat(web): opt into environment dictation on this device | skip: environment dictation, CW has no voice input |
| bc1eb5d32a | #31799 | files | fix(voice): insert Unicode word boundaries for dictation | skip: CW has no voice input |
| c09060b62b | #32045 | settings | feat(web): sort and filter transcription models | skip: transcription models |
| 40dc2910ea | #32142 | thread | fix(clients): dictating a citation comment or preview annotation uses the full width | skip: dictation |
| d5fc29fe5c | #31778 | connections | fix(web): relay-connected microphone destinations authorize speech requests | skip: dictation |
| fe901ac7ba | #31769 | connections | feat(voice): opt into cloud dictation with OpenAI, Grok, or OpenRouter | skip: cloud dictation |
| 4bd82b2177 | #32197 | browser | fix(web): make first-run dictation setup discoverable | skip: dictation |
| 15b7275595 | #32035 | settings | fix(web): first-run voice setup offers a model for the user's language | skip: dictation |
| d5290e9167 | #33133 | composer | fix(web): mic button always sits next to send | skip: CW has no voice input |
| 6b02cbff3a | #31956 | settings | fix(speech): match reference benchmarks to transcription hardware | skip: speech benchmarks |
| 55a94e2029 | #33140 | settings | fix(web): voice settings and dictation match the rest of the app | skip: dictation |
| 91a76cf5a6 | #35467 | composer | fix(web): voice dictionary keeps the draft when Enter confirms an IME candidate | skip: voice dictionary |
| a05a3cd584 | #35489 | thread | fix(shared): voice cleanup falls back after removing an instance named like an Object key | skip: voice cleanup |
| 1001bc71fc | #32682 | thread | fix(voice): dictation survives draft changes and Escape in the citation box | skip: dictation |
| 147de34a93 | #32648 | settings | fix(web): stop held dictation when shortcut modifiers are released | skip: dictation |
| 2f30d98fab | #32960 | composer | fix(web): live dictation transcript keeps the newest words in view | skip: dictation |
| 4247b5aa1a | #34380 | settings | feat(voice): add a native streaming transcription toggle | skip: streaming transcription |
| c24255826b | #35761 | settings | feat(web): dictation keeps recording into its thread when you switch away | skip: dictation |
| dd40cb51ea | #38172 | thread | fix(web): dictating a citation comment keeps Save beside Cancel | skip: CW has no voice input |
| bfd37b2b53 | #33336 | settings | feat(speech): recommend local models by language, speed and accuracy | skip: speech models |

## New feature chat-mode (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 3d78e915e3 | #30000 | settings | feat(web): a Labs setting hides tool calls so threads read like a chat | ported (settings-4928): Show all, Hide successful and Hide all filter the timeline; Zen shows the prompts, each ended turn's final answer, steer answers and errors, with no folds and no working row once the answer lands (thread-2, TimelineRows `filteringToolCalls`). Left: Zen's live answer line in the working row (`liveAnswerPreview`) |

## New feature reclaim-db (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 8969e1d8d0 | #32941 | settings | feat: Settings reclaims freed database space in one click | ported (settings-3): Storage Database rows offer Reclaim with the confirm, Restarting… and the last failure when the server can reclaim (StorageSettingsView, DatabaseStorageStatus); the environment:maintain check is left to the server |

## New feature prompt-suggestions (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| b24959d579 | #28047 | composer | feat: Labs option to suggest your next prompt after Claude and Codex turns | left: needs `orchestration.subscribePromptSuggestion {threadId}` (stream of `{runId, text} | ported: on a server whose settings have `promptSuggestionsEnabled`, the open thread subscribes to `orchestration.subscribePromptSuggestion` once it has a run; the suggestion takes the default placeholder's place with an outline `⇥ Tab` (KbdView `outline`, new kbd-outline reference), Tab in the empty prompt takes it and Escape dismisses it per run (ComposerPromptSuggestion, ComposerView `promptSuggestion`, ComposerController). Left: the Labs switch in Settings, which writes the server setting (Features/Settings); the Labs switch is ported (settings-2, BetaSettingsView.swift) |
| b48b8ea2a0 | #33706 | thread | fix(web): prompt suggestions show after a steered turn | ported with #28047: a steered run that never started is skipped (ComposerPromptSuggestion.offered) |

## New feature text-generators (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| eb97d82156 | #33147 | pr/git | feat: text generators let model APIs write titles, commits, and transcript cleanup | port; needs wire: text generator settings |

## New feature model-mentions (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 88109cea46 | #31207 | composer | feat(web,mobile): @-mention a model to name it for the agent | ported: `@` lists up to 8 models of ready instances whose names start a word for every query word, after machines and threads (ComposerModelMentions.items); a pick writes `model:<instance>/<slug>`, and the editor chips a reference the server lists, followed by whitespace, with the provider logo and the model accent in the logo's hue (ComposerChipLook `.model`). Sent messages chip known references too, copying the source (thread-2, MarkdownContextChips `modelDocument`). Left: the chip's popover (a tooltip for now), chips in assistant replies, and skipping `$…$` math (no composer math ranges in CW yet) composer-5: the composer chip now opens its popover (label, provider, source in mono; ModelMentionDetailsView, side top, w-96, compact). Still left: chips in assistant replies and `$…$` math. |

## New feature mcp-client-setup (3)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 965ddc1d6c | #33196 | connections | feat(web,server): use T3 Code in another app (MCP) | port; use T3 Code in another app |
| 8226715813 | #33663 | thread | fix(web): "Use T3 Code in another app" opens the Grok Bot app | port |
| 7f6ba5bd24 | #35565 | thread | fix(web): Grok Bot opens with the setup message filled in | port |

## New feature regenerate-title (3)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| cfb7cae2b9 | #33987 | settings | feat(web): bindable shortcut to regenerate a thread's title | ported (settings-4928): thread.regenerateTitle is listed in Keybindings and regenerates the open thread's title; the wire command was already there |
| 1c9ea568a1 | #31418 | sidebar | fix(clients): report title regeneration outcomes | left (composer-5, checked): T3 reports each regeneration as renamed, kept ("Title kept") or failed, from `thread.lastTitleRegeneration` (requestId, status, message, completedAt) the server now projects (threadTitle.ts:14-25, threadTitleRegenerationToast.ts). Needs the field decoded in T3Protocol thread shells behind a capability check, the regenerate path to wait for its requestId, and the toasts in SidebarCommands |
| ccf96b2f65 | #29383 | sidebar | feat(web): sidebar titles glimmer while they regenerate | ported 9a0153d1 |

## New feature i18n (11)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 2a6b2c8298 | #31313 | settings | feat(web): switch the UI language from Settings, with Spanish and Chinese | left (settings-3): plan and counts in docs/research/translation-4928.md (T3 catalogs keyed by hash, 3,853 CandyWrapper strings already have a key, about 9 to 12 hours of agent work) |
| afade9b562 | #33161 | settings | feat(web): add Brazilian Portuguese translation | left (settings-3): with #31313, see docs/research/translation-4928.md |
| 93d502f237 | #33162 | settings | feat(web): add French translation | left (settings-3): with #31313, see docs/research/translation-4928.md |
| d8631c8711 | #33163 | settings | feat(web): add German translation | left (settings-3): with #31313, see docs/research/translation-4928.md |
| 2718951b9f | #33164 | settings | feat(web): add Japanese translation | left (settings-3): with #31313, see docs/research/translation-4928.md |
| fdefab4df3 | #33165 | settings | feat(web): add Korean translation | left (settings-3): with #31313, see docs/research/translation-4928.md |
| 13eb5c95a6 | #33166 | settings | feat(web): add Russian translation | left (settings-3): with #31313, see docs/research/translation-4928.md |
| b823ddadd9 | #37954 | thread | fix(i18n): catalogs match the source, with a CI check | port |
| 055b44919e | #37893 | settings | feat(web,mobile,desktop): translate the whole app into every supported language | left (settings-3): with #31313, see docs/research/translation-4928.md |
| 759a173e15 | #38565 | terminal | fix(web): idle numbered terminals show their name in the app language | port |
| 6ea01d4cbe | #38649 | settings | fix(web): No project folder follows the app language | left (settings-3): with #31313, see docs/research/translation-4928.md |

## New feature reply-to-response (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| c0f85e7f79 | #33124 | thread | feat(web): reply to an assistant response from its hover actions | ported: a finished assistant message gets Reply (TimelineMessageRows `AssistantMetaContent`), the composer shows "Replying to" with the response's opening as a link and Cancel reply, and the send leads with a `response` reference and record carrying its subagents (ComposerReply, ComposerController `replyToResponse`); behind `serverUpdateStaging` since 3824 rejects the kind. The sent message draws its reference as the reply card, subagent names over the response's opening, and a click goes to the response (thread-2, MarkdownLayout `citationParagraph`). Left: the stash keeping a reply |

## New feature agent-theming (5)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 42057b82d0 | #35247 | settings | feat: agents can restyle T3 Code with theme colors and CSS | left (settings-3): CandyWrapper has no CSS engine; needs a decision on theme CSS (themeCss.ts strips every value themeCssValueFetches flags; a native port could read only :root custom properties for known tokens after that check) |
| c3517ec0bf | #36696 | settings | fix(shared): theme CSS checks allow url() inside a quoted data: address | left (settings-3): CandyWrapper has no CSS engine; needs a decision on theme CSS (themeCss.ts strips every value themeCssValueFetches flags; a native port could read only :root custom properties for known tokens after that check) |
| e82050b8b9 | #36656 | settings | feat(themes): theme CSS can hold 50,000 characters | left (settings-3): CandyWrapper has no CSS engine; needs a decision on theme CSS (themeCss.ts strips every value themeCssValueFetches flags; a native port could read only :root custom properties for known tokens after that check) |
| 9d28fc921b | #37781 | settings | feat(themes): theme CSS can hold 100,000 characters | left (settings-3): CandyWrapper has no CSS engine; needs a decision on theme CSS (themeCss.ts strips every value themeCssValueFetches flags; a native port could read only :root custom properties for known tokens after that check) |
| 31706f3d41 | #38150 | settings | fix(shared): theme CSS check no longer rejects @import text inside a string | left (settings-3): CandyWrapper has no CSS engine; needs a decision on theme CSS (themeCss.ts strips every value themeCssValueFetches flags; a native port could read only :root custom properties for known tokens after that check) |

## New feature connect-device-approval (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| a2edd281df | #36419 | device | feat(connect): require approval for new T3 Connect devices | ported (settings-4928): Connections lists requests and trusted devices with Approve, Deny and Revoke, the Require approval switch, the revoke dialog, and the waiting text on the client |

## New feature theme-backgrounds (4)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 7d32075e37 | #36680 | settings | feat(web): themes can use full-size background images | left (settings-3): needs assets.createUrl with environment-theme-background, an HTTP fetch into an image behind the window, and retries at 1, 2, 4 and 8 s (themeBackground.ts) |
| b75424062a | #37843 | settings | fix(web): retry a failed theme wallpaper download when back online | left (settings-3): needs assets.createUrl with environment-theme-background, an HTTP fetch into an image behind the window, and retries at 1, 2, 4 and 8 s (themeBackground.ts) |
| 49c3ab8632 | #37981 | settings | fix(web): published background no longer shows under a saved theme with the same id | left (settings-3): needs assets.createUrl with environment-theme-background, an HTTP fetch into an image behind the window, and retries at 1, 2, 4 and 8 s (themeBackground.ts) |
| 28d2262083 | #38132 | pr/git | fix(web): theme wallpaper stays in the live preview when connectivity returns | port |

## New feature issues (22)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 85dcfa61ca | #19260 | issues | feat(web): add the Issues page and issue detail panel | ported 39a3ad7d, 0a5ca190: the page, the panel, the issue tab |
| 0597b9edcd | #19270 | issues | feat(issues): link issues to threads and expose issue tools to agents | port; needs wire: issue links and tools |
| 86863beede | #19274 | issues | feat(issues): add Linear as a standalone issue tracker | partly: Linear rows, mark and panel; connecting Linear and binding projects (`issueTrackers.*`, IssueTrackerSettings) left |
| 60f7e5d9b1 | #37760 | issues | feat(issues): filter the issue list by label and assignee, and sort it | ported 39a3ad7d: label and assignee filters and the sort; the candidate submenus have no search field |
| bb29ee3e71 | #37963 | issues | feat(issues): save named filter views on web and mobile | ported 39a3ad7d, 1aafa321: saved views on Issues and Pull Requests |
| b78914e4f3 | #37971 | issues | fix(client-runtime): Linear filters keep their choices when a search has no matches | ported 39a3ad7d: chosen labels lead the menu |
| 983654b3b2 | #38190 | issues | fix(web): an invalid host filter in an Issues link no longer crashes the page | ported 0a5ca190: a remembered host stays a menu choice, preferences bounded |
| b4dfd75624 | #38205 | issues | fix(client-runtime): issues held by two environments list once | ported 39a3ad7d: rows dedupe by URL |
| e3949714e3 | #38309 | issues | fix(web): restore the Issues right panel shortcut | ported 0a5ca190 at the default Mod+Alt+B |
| b648395fa5 | #38489 | issues | fix(web): older comments no longer reappear after refreshing an issue | ported 0a5ca190: older pages reset on a refresh that moves the cursor |
| 1c41c5ed89 | #38508 | issues | fix(azure-devops): issue lists reuse each project's states and survive a refresh while loading | n/a: server side; the page keeps rows while a refresh loads |
| 2d558c4dad | #38537 | issues | fix(web): the issue viewer shows why a refresh failed | ported 39a3ad7d: "Could not refresh this issue" |
| 6a29d58d14 | #38493 | issues | fix(client-runtime): closed issue searches no longer build up in memory | n/a: client-runtime cache internals; CandyWrapper holds one answer per environment |
| f1d64aa0b6 | #38263 | pr/git | fix(azure-devops): legacy and project-less remotes list their work items | port |
| 378584a760 | #38294 | issues | feat(web): hovering an issue link shows its preview card | ported (panels-3): hovering a GitHub or GitLab issue link a project here reads shows IssueLinkPreviewView after issues.detail, spec, reference and IssueLinkPreviewFidelityTests; the branch is in App PullRequestsController's MarkdownLinkHandler (showIssuePreview), Features/Markdown untouched; Linear links and the PR card's issue fallback left (need tracker bindings) |
| b6a0fd6d62 | #38771 | issues | feat(issues): an issue shows every thread it is linked to | ported 0a5ca190: the linked-threads count opens the palette on the issue URL; the thread picker that links from the Pull Requests and Issues pages is in (panels-3, ThreadLinkPicker with spec, reference and test) |
| c350ee7e15 | #38256 | issues | feat(web): filter the issues list by project | ported 39a3ad7d: the Project filter |
| 2e3d9fccdd | #38282 | issues | feat(web): show linked issues beside thread pull requests | ported 9a0153d1, composer-4: the sidebar badge, and since composer-4 its state icon and tone from `issues.detail` for a single issue (SidebarThreadRow.tsx:1137-1171, issuePresentation.tsx:33-53); new issue-badge.open and .completed spec cases. Left: the hover list of issues (ThreadDetailsIssueRows), with #38160 in Features/Thread |
| 63899c16b9 | #38654 | issues | fix(web): retrying a failed Issues list no longer restarts another environment's read | ported 0a5ca190: Retry reads every environment again in one generation |
| 966bdc74f3 | #38854 | issues | fix(client): Linear issue links in messages open in the issue panel | port |
| 60e54867fc | #38986 | issues | fix(azure-devops): refreshing Issues reads each project's current finished states | n/a: server side |
| 1d5ebe3f8e | #39000 | issues | fix(client-runtime): a failed issue refresh keeps older comments already loaded | ported 0a5ca190: a failed refresh keeps the loaded comments |

## New feature pr-saved-views (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 2d265dc410 | #29387 | pr/git | feat(prs): save named filter views across clients | port; needs wire: saved filter views |

## New feature fx-backend (1)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 00c6adbdce | #29388 | thread | feat(fx): choose a backend per thread | ported: `subProviders` decodes, a provider lists each backend as a collapsible heading with its count or Unavailable reason, the active backend opens expanded, and a warning provider with a usable backend stays ready (ModelCatalog, ModelPickerView) |

## Small fixes, browser (18)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 8f6c9b7144 | #23338 | browser | fix(web): preserve typed dimensions with the aspect ratio locked | already in CandyWrapper (panels-3): with the lock on, BrowserDeviceToolbarView.edit keeps the typed field's text and rewrites only the other field |
| 083c903950 | #26233 | browser | fix(web): right panel's tab bar no longer slides under the title bar controls | left (panels-3): the right panel's close motion lives in Features/Thread RightPanelView, another agent's area; needs an on-screen check of the tab bar against the title bar controls |
| cde3620577 | #26633 | browser | fix(web): forward native Copy and Cut from server browser tabs | ported (panels-3): Edit menu Copy and Cut send Control+C or X to a server tab the user controls, ServerBrowserView.copy/cut |
| 9cb59bf858 | #22328 | browser | fix(web): mod+L focuses the browser address bar from a focused page | already in CandyWrapper (panels-3): the shortcut registry runs preview.focusUrl whatever has focus (BrowserController.swift:907-911); on-screen check wanted with the page focused |
| 17948307cc | #28064 | browser | fix(client): the folder browser shows folders added or removed while T3 runs | already in CandyWrapper (panels-3): PaletteAddProject drops its folder listings each time the palette closes (reset(), browseCache), so a reopened browser reads folders fresh |
| 6717d92cf3 | #28243 | browser | fix(web): Tab completes folder names in the add-project browser | ported (panels-2): Tab opens the highlighted or only folder, or extends to the common prefix, Mode.onTab in CommandPaletteController |
| b5d9f85b9a | #26027 | browser | fix(web): keep inward mini browser resizes from growing | ported (panels-3): an inward drag keeps a player already under the 240pt minimum, BrowserMiniPlayerResizeDirection.resized |
| 1436c4571f | #29347 | browser | fix(client-runtime): connect to the primary environment while the browser reports offline | already in CandyWrapper (panels-3): a loopback primary ignores offline reports (ConnectionSupervisor ignoresOffline, RouteKind.isLoopback) |
| 350ecd63be | #32569 | browser | fix(web): closing the right panel returns focus to where it was | left (panels-3): returning focus when the right panel closes belongs to Features/Thread RightPanelView, another agent's area |
| 7c76c9ddc2 | #30882 | browser | fix(web): mouse back/forward over the right panel no longer moves the main chat | ported (panels-3): the mouse's back and forward buttons over a server tab move its history and nothing else, ServerBrowserView.onThumbNavigate; CandyWrapper's chat has no thumb navigation to move |
| 2e18418abf | #34859 | browser | fix(web): Incognito browser visits stay out of project history | ported (panels-3): an address bar visit in an Incognito tab stays out of the project's history, BrowserController onSubmit |
| e6119fdf68 | #35143 | browser | fix(web): browser settings changed in project scope no longer overwrite the global default | left (panels-3): browser settings in project scope live in Features/Settings, held for the Settings agent |
| ff1eead6f4 | #35947 | browser | fix(web): zoom shortcuts work while a desktop browser page has focus | already in CandyWrapper (panels-3): zoom shortcuts go through the same registry as preview.focusUrl, so a focused page keeps them; on-screen check wanted |
| 0f13d638af | #29475 | browser | fix(browser): Stop cancels loading pages | ported (panels-3): the refresh button stops a loading page and its tooltip says Stop; sends `stopLoading`, which 3824 servers ignore |
| be5f805964 | #34943 | browser | fix(web): new desktop browser tabs open at the default zoom and appearance | n/a (panels-3): desktop (Electron) tabs; CandyWrapper's server tabs get the same defaults through #25874 |
| 651accb100 | #25874 | browser | fix(web): new browser tabs open at your default zoom and appearance | ported (panels-3): preview.open carries browserDefaultZoomFactor and browserDefaultAppearance, PreviewRPC.openPayload |
| 675fb1d9a7 | #36846 | browser | fix(web): show Browser device preferences read-only for projects | left (panels-3): Browser device preferences read-only for projects is a Features/Settings change, held for the Settings agent |
| 6fc2fb192c | #35299 | browser | fix(web): desktop browser tabs show native navigation immediately | n/a (panels-3): Electron tab navigation state; CandyWrapper has only server tabs |

## Small fixes, composer (120)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 4453f537ff | #26929 | composer | fix(web): Antigravity effort no longer shows a speedometer in the composer | ported in part (composer-4): `thinking_level` joins the effort ids (threadExecution.ts:227-234). Left: the traits trigger word for composer-owned traits with no effort glyph (TraitsPicker.tsx:619-624, 703-711), which needs composerControlsOwnership's traits split in ComposerPickers |
| 88ab83e8bc | #26958 | composer | fix(web): reconnecting notice no longer shifts the new thread composer | left (composer-5, checked): T3 shows a draft page's notices as detached cards (`detached`: whole rounded cards, no seam, no overlap) out of flow 16pt below the centered composer with 4pt gaps (ChatView.tsx:3896-3901, ComposerBannerStack.tsx); CW still stacks them attached between the hero and the composer. Needs ThreadPanelView's draft branch to lay them out below with `placement = .floating`, in Features/Thread |
| 4b7a347ca9 | #23174 | composer | fix(composer): retry expired catalogs after failed discovery | already in CandyWrapper (composer-5): CW keeps no failure counter; `refreshWorkspaceSnapshot` asks again once the 5-minute TTL passes, and forgets a failed ask at once |
| e836ab1275 | #21508 | composer | fix(web): right panel launcher letters work on non-Latin keyboard layouts | left: belongs with the right panel launcher keys, outside the composer; not checked this session |
| dcf051e861 | #21537 | composer | fix(composer): copied context with an apostrophe survives the HTML clipboard | ported: the clipboard fragment ends only at its own quote style (ComposerContext `fragmentAttribute`) |
| b665f0b11c | #23446 | composer | fix(web): recognize plain text aliases in code fences | ported: `plaintext` and `txt` fences read as Plain text (ComposerCodeLanguages.aliases) |
| 42ca5d560d | #23447 | composer | fix(web): keep deleted clipboard attachments out of the draft | ported (composer-5): a pasted attachment chip whose bytes are still downloading stays out of the draft when the user deleted the chip meanwhile (ComposerController `importPastedAttachment`) |
| 2274ff9a5d | #27033 | composer | fix(web): Compact chip fits on narrow composers | ported: at 480pt and under the Compact chip shows its count alone (ComposerCompactPill `narrow`) |
| 7c90d51d61 | #23957 | composer | fix(web): composer keeps the picked effort when it falls back to another instance | left (composer-5, checked): T3 keeps the picked effort when a disabled instance falls back to another (`requestedInstanceId`, `withFallbackInstanceOptions`); needs a port into T3Store ComposerSelectionStore/ComposerSelectionContext with T3's tests |
| 7917ac895b | #24697 | composer | fix(web): Resume keeps its thread's model when you switch threads | already in CandyWrapper: Resume reads the model selection before its first await (ComposerController `resume`) |
| 6e1bec50d5 | #26470 | composer | fix(web): prevent permissions label from shrinking on click | skip: adds `aria-haspopup` to the strip control only |
| 7d7db0cbc3 | #26514 | composer | fix(web): remove gaps between permission options | ported: the permission segments touch, and only the outer ends round (ComposerPermissionsView.layout) |
| 00b2d0e271 | #26559 | composer | fix(web): the prompt box follows the interface font size | ported (composer-5): without Advanced typography the prompt uses the interface family at `text-sm` of the interface size; only Advanced applies its own font and size (FontRuntime.apply, test in FontRuntimeTests) |
| e00f98fde2 | #22236 | composer | fix(web): stacked composer notices line up their details buttons | ported: a notice's actions take at least 48pt, so stacked notices line up their details buttons (ComposerNoticeBannerView.layout) |
| a0aefbee11 | #23784 | composer | fix(shared): give attached threads a canonical read call | free with the runtime: the server formats the thread record's read call (packages/shared composerContextReferences.ts runs in ProviderTurnStartService) |
| 8003dd8c7b | #27016 | composer | fix(web): Shift+Tab moves a nested composer list item back out | ported: Shift+Tab lifts a nested item to its parent indent and renumbers the parent list (ComposerListContinuation `outdent`) |
| 8b74a69019 | #28446 | composer | fix(web): background command details open above their button | ported in part (composer-5): background command and monitor labels read through `commandDisplayText` (ThreadRecoveryPresentation, Features/Thread). The details popover's `whitespace-pre-wrap` and unbounded scroll are left, they need the banner details popover in ComposerNoticeBannerView checked on screen |
| cedf8b4c1c | #23940 | composer | fix(web): format inline code when the opening backtick is typed last | ported (composer-4): ComposerEditor.formatCodeBeforeClosingTick (composer-rich-text-doc.ts:81-124); ComposerCodePairTests |
| 16233e7529 | #24331 | composer | fix(web): typed answer moved to the draft by an option click is announced | ported: an option click that moves typed text into the draft toasts "Your typed text was set aside" (ComposerController `carryDisplaced`) |
| 1ad78611ba | #25511 | composer | fix(web): keep the default instance's draft model off custom instances | n/a: CandyWrapper keys draft models by instance and never had driver-keyed drafts |
| 868524f259 | #27384 | composer | fix(web): Backspace no longer re-nests a checkbox under a bullet | already in CandyWrapper: Backspace on a task under a bullet joins the line above (ComposerRichTextBlockTests backspaceAtTheStartOfALine `- a\n  - [ ] x` gives `- ax`) |
| e71f414cb0 | #27472 | composer | fix(web): Esc in the theme color picker restores the previous color | left: belongs with Settings, the theme color picker, outside the composer; not checked this session |
| 6dddccb244 | #27837 | composer | fix(shared): /Model with a query still opens the model picker | skip: superseded; 4928 composerTrigger.ts has no `/model <query>` trigger left |
| 71d52eb61b | #28083 | composer | fix(web): align composer context icons and space their labels | left: the context strip's branch, worktree and environment triggers take `gap-1.5` and the cap-aligned label in every display mode (BranchToolbarBranchSelector.tsx, BranchToolbarEnvModeSelector.tsx, BranchToolbarEnvironmentSelector.tsx, ComposerContextLabel.tsx); needs ComposerContextStripView spacing and a composer-footer recapture check |
| dc102e5062 | #28209 | composer | fix(web): skill menus show loading while project skills arrive | ported (composer-5): the skill and `/` menus say "Searching workspace skills..." while the provider's workspace snapshot ask is in flight (`workspaceScanning`) |
| ce48e45900 | #28499 | composer | fix(web): prevent composer image thumbnail flicker | n/a: React object-URL churn; CandyWrapper decodes a thumbnail once through ImageDecodeCache |
| 4ff9a32bad | #27457 | composer | fix(web): format inline code typed with a dead-key backtick | left (composer-4, checked): a dead-key backtick commits through marked text, which the code pair rule skips (`!hasMarkedText`, range.length 0); needs the composition-commit path of composer-rich-text-doc.ts (80 lines) composer-5: rechecked, still left; it is a rich text input rule port in ComposerEditor, best done with #30421. |
| 3f695422ae | #24684 | composer | fix(web): a failed plan follow-up no longer overwrites the next draft | already in CandyWrapper: a failed send, plan follow-up included, restores its text only into a draft with no newer prompt (ComposerController.sendFailed) |
| ab06e2a265 | #29165 | composer | fix(clients): attachment sizes just under 1 MB no longer read "1024 KB" | ported: ComposerFileRow.formatSize picks the unit after rounding |
| d1e5044c67 | #29158 | composer | fix(shared): context chip labels no longer split an emoji at the 200-character cap | ported: the 200-unit label cap never splits a surrogate pair (ComposerContext.sanitizeLabel) |
| 228e289506 | #29828 | composer | fix(web): drafts saved by older versions load instead of being wiped | n/a: migrates T3's own localStorage draft format; CandyWrapper keeps its drafts in UserDefaults (composer.prompts.v1) |
| 92388d5a08 | #29789 | composer | fix(web): picking a custom model named like a Codex alias keeps that model | already in CandyWrapper: picks keep the slug as given; CandyWrapper has no static alias normalization (`normalizeModelSlug`, see ThreadRelationships.swift:566) |
| 03dbb2fb48 | #24990 | composer | fix(web): adding to the composer no longer drops earlier findings and selections | left (composer-4, checked): the change is in ThreadDetailsPrRow, PullRequestDetailPanel and pullRequestDetail.logic, Features/PullRequests (another agent's area) composer-5: rechecked, the reason holds (that area's agent is still working there). |
| ecea300d3c | #28016 | composer | fix(web): sidebar search results can be dragged onto the composer | left: belongs with the sidebar search rows, outside the composer; not checked this session |
| 3fa57b92a2 | #26724 | composer | fix(web): boring sidebar threads drag onto the composer again | left: belongs with the boring sidebar rows, outside the composer; not checked this session |
| 50e176dba5 | #29018 | composer | fix(web): banner button hover follows the banner's rounded corners | left (composer-5, checked): the trailing banner action's hover fill takes the banner's top corner (12, or the control radius when joined) and a detached card's bottom corner; CW's ButtonView fills with one radius. Needs a per-corner hover radius in DesignSystem ButtonView |
| f06bfa69c7 | #33990 | composer | fix(web): drag command palette threads into the composer | left: belongs with the command palette rows, outside the composer; not checked this session |
| 1d80047048 | #34113 | composer | fix(web): scroll project picker to top on first result | left: belongs with the project picker, outside the composer; not checked this session |
| 31bf2f7f34 | #32681 | composer | fix(client-runtime): pasted repository page URLs clone the repository into its own folder | left: belongs with add project from a repository URL, outside the composer; not checked this session |
| a0efdaeb89 | #33783 | composer | fix: new threads move from draft to Working in one step | left (composer-5, checked): T3 shows a sent draft's thread as Setting up (`asLaunchingThread`: a preparing runtime while it has no run or runtime) from its shell's arrival until the server owns the send; CW has no launching overlay. Needs ComposerController to publish promoted thread ids into SidebarListState and SidebarModel to overlay `.working`/preparing for those |
| 2828f28145 | #16546 | composer | fix(web): composer follows an optionless thread instead of the settings default | ported: a started thread's options, even none, outrank the project's (T3Store ComposerSelectionStore.resolve `optionSources`) |
| d56b82c708 | #22193 | composer | fix(web): keep saved default model when changing effort | left (composer-4, checked): ProviderModelPicker.logic plus ProjectDefaultsSettings.logic; the settings half is Features/Settings (another agent's area) composer-5: rechecked, the reason holds (that area's agent is still working there). |
| 6700cf6f89 | #21968 | composer | fix(web): reveal expanded work rows hidden behind the composer | left (composer-4, checked): CommandOutputPanel, MessagesTimeline and TimelineWorkEntryRow, Features/Thread (another agent's area) composer-5: rechecked, the reason holds (that area's agent is still working there). |
| cbc68c9dc1 | #20809 | composer | fix(web): Stop shows a pending state and repeat clicks no longer resume | ported in abe98edb, without the second Stop button beside Send while typing |
| 8f4166b28c | #22997 | composer | fix(web): convert composer list markers completed later | left (composer-4, checked): typing `-a` then a space after `-` stays text in CandyWrapper; needs the later-completed list marker input rule (composer-rich-text-doc.ts, 149 lines) in ComposerEditor composer-5: rechecked, still left; it is a rich text input rule port in ComposerEditor, best done with #30421. |
| 9d7384d096 | #23289 | composer | fix(client-runtime): reopening a folder picker refreshes its listing | left: belongs with the add-project folder picker, outside the composer; not checked this session |
| 21a9aa1d79 | #14870 | composer | fix(web): wrapping a selection in backticks formats it as code | ported: a backtick typed over a one-line selection makes it code, `*` or `_` italic (ComposerEditor `surroundSelection`); T3 also checks the span reparses the same, which CW skips |
| a02bc75737 | #34572 | composer | fix(web): keep background toast Open button inline | already in CandyWrapper: the Started in background toast is a plain ToastView with Open inline (ComposerController launch path) |
| 6a5d6085ba | #32959 | composer | fix(web): prompt links work for encoded thread IDs | n/a: CandyWrapper routes by thread ids, not encoded URL pathnames (threadRoutes.ts) |
| 3de3c9ffff | #34307 | composer | fix(web): keep a leading blank line selected when indenting code | n/a: Tab in a CandyWrapper code block indents at the caret only and never indents a selection |
| ea3e20a0e2 | #27287 | composer | fix(web): double-clicking another thread in the sidebar renames it instead of focusing its composer | left: belongs with the sidebar rename, outside the composer; not checked this session |
| 4e6924753c | #27280 | composer | fix(web): pasted CRLF text keeps its blank lines and caret in the composer | ported: pasted CRLF and CR read as LF before the paste is handled (ComposerPasteboard `normalizedLineBreaks`) |
| 6a03ef6568 | #34493 | composer | fix(web): app keybindings on Mod+B, Mod+I and Mod+E win over composer formatting | already in CandyWrapper: App/Sources/ComposerController.swift:789 lets a bound app command beat the editor formatting, and Mod+B over selected text still bolds as in 4928 AppSidebarLayout.tsx:342-350 |
| 4ae66e2e86 | #24585 | composer | fix(opencode): project-defined models appear in that project's picker | left (composer-5, checked): project-defined OpenCode models in that project's picker touch ChatView, ChatComposer and the picker's project scope; needs a port into T3Store ComposerSelectionStore/ComposerSelectionContext with T3's tests and the project's provider settings |
| d9a54ec645 | #34724 | composer | fix(web): file breadcrumbs keep backslashes in POSIX folder names | left: belongs with the file breadcrumbs, outside the composer; not checked this session |
| 1a1f9ac18e | #34810 | composer | fix(web): Ctrl/Cmd+Enter sends new threads when the send shortcut needs it | ported: with a send that needs a modifier, Mod+Enter `composer.sendBackground` reads as Mod+Shift+Enter too (T3Protocol Keybindings.shortcut) |
| 7fc9aa6ed9 | #34816 | composer | fix(shared): typing after a skill chip no longer reparses the prompt as math | left (composer-4): the `mayContainDollarMath` prefilter belongs to the Markdown math pass in Features/Markdown, another agent's area; the composer has no math parsing composer-5: rechecked, the reason holds (that area's agent is still working there). |
| 2b07556d71 | #28352 | composer | fix(web): a stashed prompt ending in a skill or file chip restores as a chip | ported: a stashed prompt ending in a chip keeps one space so it restores as a chip (ComposerController `stashCurrentPrompt`) |
| 002dc9b644 | #35075 | composer | fix(web): file names with a backslash no longer split into folders in the Changes card | left: belongs with the Changes card in the thread, outside the composer; not checked this session |
| cb931fcbe2 | #35110 | composer | fix(web): a save in one tab no longer erases what another tab saved | skip: a cross-tab storage race; CW is one process with one draft store |
| 1c9d32fe3c | #35137 | composer | fix(shared): composer # suggestions sort by update instant, not timestamp text | ported: `#` suggestions sort by update instant (ComposerMenus.pullRequestItems) |
| 0cd6a73433 | #35265 | composer | fix(web): pasting an image the draft already has no longer flashes a preparing tile | n/a (composer-5): CW does not dedupe pasted images (no `composerImageDedupKey`), so there is no hidden duplicate tile to flash; image dedupe itself is a gap, see #37116 |
| 86ff9d073c | #35454 | composer | fix(web): Prompt Stash shrinks above the composer when vertical space is short | already in CandyWrapper (composer-5): ThreadPanelView caps the stash drawer at the space above the composer, at least 96pt, and the list scrolls |
| 9b242e4d07 | #27414 | composer | fix(web): reveal full composer command descriptions | ported (composer-5): the active composer menu row shows its full description in a tooltip while it is cut off (MenuRowView `descriptionTip`) |
| 05089062d4 | #29179 | composer | fix(web): restore composer focus when returning to a thread | already in CandyWrapper: loadPrompt focuses the composer whenever a thread or draft opens |
| a98bc69676 | #24872 | composer | fix(web): Cursor threads keep a stored model the catalog doesn't list | left (composer-5, checked): a Cursor thread keeps a stored model the catalog doesn't list (modelSelection.ts, useComposerSelection.ts); needs a port into T3Store ComposerSelectionStore/ComposerSelectionContext with T3's tests |
| 0bb6eaa546 | #35658 | composer | fix(web): auto-balanced drafts recheck machine load before sending | left (composer-5, checked): auto-balanced drafts ask the machines' load again before sending (useDraftEnvironmentRouting.ts, useLoadBalancedEnvironment.ts, 84 lines); needs ComposerController's auto-balance send path to re-resolve `loadBalancedEnvironmentId` before dispatch |
| d7a0b5371f | #33782 | composer | fix(web,mobile): triage follows the draft when you switch machines | left (composer-5, checked): triage follows the draft when its machine changes (DraftHeroHeadline.tsx, useDraftEnvironmentRouting.ts); needs the draft hero's triage source to follow `target.environmentId` |
| 96a4d2f012 | #36363 | composer | fix(web): pasted URLs and paths keep their underscores | ported (composer-4): ComposerRichText.literalUnderscoreRuns keeps underscores in URLs, paths and file names (composer-rich-text.ts:35-70); T3 cases in ComposerRichTextT3InlineTests |
| 2d689687f5 | #36435 | composer | fix(web): bare @ in the composer lists workspace files | ported: a bare `@` searches the workspace with an empty query, which 3824 and 4928 accept (ComposerController `startSearches`) |
| 2dd6cddbc3 | #36504 | composer | fix(shared): @ mentions complete display names in any script | skip: belongs with the pull request composer's `@` and `#` trigger (pullRequestComposerTrigger.ts), Features/PullRequests |
| 7847ec9386 | #35741 | composer | fix(web): preserve queued project settings changes | left (composer-4, checked): scopedSettings.ts and useScopedSettings.ts, Features/Settings (another agent's area) composer-5: rechecked, the reason holds (that area's agent is still working there). |
| ac180919a6 | #24619 | composer | fix(web): seeded models yield to started thread selections | left (composer-5, checked): seeded models yield to a started thread's selection (ChatView.logic.ts, CommandPalette); needs a port into T3Store ComposerSelectionStore/ComposerSelectionContext with T3's tests |
| 3fe0fbb69f | #36572 | composer | fix(web): keep file uploads when returning a draft to its environment | n/a: CandyWrapper keeps no per-file upload stamp on scratch drafts to restore |
| fd0ffd0b0a | #36574 | composer | fix(web): a stale tab no longer erases finalized stashed images | skip: a cross-tab storage race; CW is one process with one draft store |
| 5e06246d24 | #36578 | composer | fix(web): recovered queued edits keep their mentions and context | already in CandyWrapper (composer-5, checked): a queued edit's prompt keeps its thread and machine records through `persistedIdentityRecords`, saved with the draft and restored with it; CW has no separate edit-target draft to move back |
| 820f620e3d | #36621 | composer | fix(web): model picks no longer inherit another model’s traits | left (composer-5, checked): a draft pick of another model takes none of the base thread or project options (`composerModelIdentity`, composerDraftStore.ts); needs a port into T3Store ComposerSelectionStore/ComposerSelectionContext with T3's tests |
| fd6d0ea022 | #28308 | composer | fix(web): stashing waits for pasted images to finish compressing | already in CandyWrapper: stashing while a pasted image is prepared toasts and waits (ComposerController `stashCurrentPrompt`) |
| 5e27bae22e | #28780 | composer | fix(web): a stashed prompt keeps its machine mentions | ported (composer-4): restoring a stash with machine mentions while a question is open is refused with T3's toast, before and after the file check (useComposerStash.ts at 4928) |
| f84ad6f30b | #36732 | composer | fix(web): discarded drafts stay discarded after image compression | ported (composer-4): discarding a draft drops images still compressing for it (`cancelPreparingComposerImages`, preparingComposerImages.ts at 4928) |
| 081a5d92bf | #29617 | composer | fix(clients): the folder picker finds folders with accented names on macOS | left: belongs with the add-project folder picker, outside the composer; not checked this session |
| 4954322f02 | #27458 | composer | fix(web): don't send completion notifications for snoozed threads | ported (panels-2): snoozed threads send no completion, including one that landed during the snooze and arrived after the wake |
| f751c8488f | #29846 | composer | fix(web): the new-thread project picker follows the manual project order | left: belongs with the project picker, outside the composer; not checked this session |
| 1f45f14ae8 | #33298 | composer | fix(web): queued images open in the image viewer | ported (composer-5): a queued message's loaded image thumbnail opens the image viewer at that image, with the message's other images (QueuedRunsView `onExpandImage`); the zoom-in cursor is left |
| 619c652d25 | #35176 | composer | fix(web): retain custom model drafts until saved | left (composer-4, checked): ProviderInstanceCard and ProviderModelsSection, Features/Settings (another agent's area) composer-5: rechecked, the reason holds (that area's agent is still working there). |
| ec01233fb6 | #35528 | composer | fix(web): pasted images stay at their original insertion point | ported (composer-5): a pasted image's chip lands at the paste point once prepared, before text typed there since; if the text before that point changed, at the caret (ComposerView `InsertionMark`, tests in ComposerInsertionMarkTests) |
| 1ea5e4b42d | #35122 | composer | fix(web): typing in the file editor no longer jumps to the prompt | left: belongs with the file editor, outside the composer; not checked this session |
| 37c266d25a | #34537 | composer | fix(web): showing a composer banner no longer makes the page restyle everything until reload | skip: browser style recalculation after a banner mounts; no AppKit counterpart |
| cbdf35f2f0 | #23166 | composer | fix(web): enable Send when the composer holds only a thread context | already in CandyWrapper: thread and machine contexts are chips in the prompt text, so the prompt is never empty and Send stays enabled |
| 62405fce57 | #30583 | composer | fix(web): preserve thread identity across composer pastes | ported (composer-5): a pasted thread reuses the draft's record for the same thread and remints only on an id collision (`ComposerContextImport.plan`, tests ported) |
| 2b7fc890de | #30947 | composer | fix(web): a send that finishes after you leave its thread no longer blanks the open thread's composer | already in CandyWrapper: a send clears the editor synchronously on the thread it sends from, before any await (ComposerController.send) |
| 3c8f3f2c3d | #31314 | composer | fix(web): up-arrow recall keeps thread and machine mentions | ported (composer-5): Up-arrow recall brings the recalled message's thread and machine records back (ComposerView `onHistoryRecall`, ComposerController), so its mentions stay chips for the machine they name |
| 6f8144b5c4 | #37010 | composer | fix(web): overlapping image pastes keep their prompt order | ported (composer-5): overlapping image pastes at one point keep paste order (ComposerView `InsertionMark` order, tested) |
| 617c6c74f6 | #31541 | composer | fix(web): thread chips in the composer can no longer be dragged out as links | n/a: CandyWrapper's chips are text attachments, not links, so they never drag out as URLs |
| ed6cb97f07 | #31880 | composer | fix(web): reopened composer drafts keep quote spacing and show the caret | ported (composer-4): a reopened quote keeps its spacing through the same separator load; the caret part is Tiptap focus handling, n/a |
| 1cec1043eb | #31593 | composer | fix(shared): file mentions of __init__.py keep their name as the label | ported: file link labels escape `*` and `_` too (ComposerInlineTokens.fileLink) |
| 189290cbf0 | #24082 | composer | fix(web): [NIT] SF Pro label no longer renders in a serif in the font picker | left: belongs with Settings, the font picker, outside the composer; not checked this session |
| f52fba48d9 | #32683 | composer | fix(web): stacked composer banners no longer show dark seam bands | ported (composer-5): only the attachment touching the composer draws the dark seam shade; one with another docked under it (`dockedBelow`, set by ComposerBannerStack and ThreadPanelView's attachment chain) draws none. Dark-mode pixel test ComposerBannerSeamTests |
| 8e06750a08 | #32709 | composer | fix(web): draft images keep their order after a reload | already in CandyWrapper: persistDraftAttachments writes each draft's attachments in their order and restoreDraftAttachments appends them back in it |
| ca31ab64a4 | #32732 | composer | fix(web): an image-only send that fails behind a new draft now says so | skip: CW has no "Message not sent, your new draft was kept" toast for a send that fails behind a newer draft; a failed send restores the draft and shows the thread error banner |
| 2dc5ebd52f | #33090 | composer | fix(web): switching providers no longer drops the thread's stored effort | left (composer-5, checked): switching providers keeps the thread's stored effort (useComposerSelection.ts); needs a port into T3Store ComposerSelectionStore/ComposerSelectionContext with T3's tests |
| f2c944947d | #32910 | composer | fix(web): recover expired composer uploads before sending | ported: a send first asks `assets.createUrl` for each ready upload; a swept one uploads again from its local copy and the send goes after, one without a copy fails with "Uploaded attachment expired. Remove it and attach it again.", and a failed check with T3's retry reason (ComposerController `verifyUploadBeforeSend`). Skipped: T3's branch for sessions without the orchestration read scope, which CW sessions always have |
| 7d9c365e17 | #37116 | composer | fix(web): keep distinct images with matching attachment metadata | left (composer-5, checked): distinct images with the same name, type and size stay apart; CW has no image dedupe at all (see #35265), so this needs T3's `composerImageDedupKey` dedupe ported first |
| 0b489dada1 | #37208 | composer | fix(web): switching a draft’s machine keeps its selected models | left (composer-5, checked): switching a draft's machine keeps its selected models where the new machine has them (useDraftEnvironmentRouting.ts, 31 lines); needs a port into T3Store ComposerSelectionStore/ComposerSelectionContext with T3's tests |
| 256dce7f1f | #37243 | composer | fix(web,mobile): @ picker finds older settled threads on linked machines | ported (composer-4): `@` searches older settled threads on the target and each linked machine and labels them with the machine (useComposerMenuItems.ts:126-132) |
| 3cf00c3e8b | #37495 | composer | fix(web): composer drafts keep underscores in non-Latin names | ported (composer-4): underscore emphasis reads word characters in any script (`[\p{L}\p{M}\p{N}_]`, composer-rich-text.ts:31-33, 121-127) |
| 506a0438a3 | #37528 | composer | fix(web): keep Pi and ACP model selections during catalog gaps | left (composer-5, checked): Pi and ACP selections survive catalog gaps (ModelPickerContent, TraitsPicker); needs a port into T3Store ComposerSelectionStore/ComposerSelectionContext with T3's tests |
| 50b885e036 | #37593 | composer | fix(web): switching a draft's machine uses that machine's default model | left (composer-5, checked): a draft moved to another machine takes that machine's default model (AddProjectToMachineDialog, DraftHeroHeadline); needs a port into T3Store ComposerSelectionStore/ComposerSelectionContext with T3's tests |
| bcb0604581 | #37661 | composer | fix(web): model picker options no longer jump a pixel on hover | skip: Chromium re-snaps text after the popover scale-in at fractional zoom; AppKit draws the rows at fixed positions |
| 6f5838f9bc | #37691 | composer | fix(client-runtime): a relative "Add project starts in" opens the picker under home | left: belongs with the add-project folder picker, outside the composer; not checked this session |
| caef8c3847 | #32912 | composer | fix(composer): show local command actions while running | ported (composer-5): while a turn runs, a text-only `/usage-limits`, `/feedback` to Codex, `/clear` or a side chat command shows the plain send button instead of queue or steer (ComposerView `runsDraftLocally`, composerDispatch.ts:59-74) |
| c69f4b780b | #31590 | composer | fix(web): model picker lists a model reported twice once | ported: ModelPickerSections lists a model reported twice once |
| 750e492ed6 | #37771 | composer | feat(web): copy snapshots into another composer | ported in part (composer-5): copied attachment chips carry their record, source and file, a paste imports them under new ids, context on the clipboard wins over its image, and a draft snapshot's accessibility popover has Copy snapshot; the sent message's and expanded dialog's Copy snapshot buttons are in Features/Thread, left |
| e514c36f3c | #31174 | composer | fix(web): project picker jump shortcuts follow the filtered rows | left: belongs with the project picker, outside the composer; not checked this session |
| f39ecd3df8 | #29663 | composer | fix(web): a rule typed under a line stays a rule when sent | ported (composer-4): a dash rule under a line of prose is written after a blank line, consumed again on load (composer-rich-text-doc.ts:1267-1272) |
| 8753e4d36b | #31283 | composer | fix(web,mobile): Send now tells you why it could not send | ported: a failed Send now on a queued message shows "Could not send queued message" with the reason (ComposerFeedback `queueSendNow`) |
| 3e1b7c4e93 | #38414 | composer | fix(web): a line typed after a composer list is sent after the list | ported (composer-4): the serializer writes a blank line between a list and the prose after it, ahead of empty lines, and setText consumes it on load (`needsBlankLineBetween`, `blockSeparator`, composer-rich-text-doc.ts:1090-1107, 1254-1273); ported tests follow T3 4928 expectations |
| 01cfac429d | #38475 | composer | fix(web): Paste as Text pastes text when the clipboard also holds an image | ported: Paste as Text skips the image attachment when the clipboard also holds text (ComposerEditor `paste`) |
| ad77fd88e2 | #37547 | composer | fix(web): Enter during image compression sends once it finishes | ported: Enter while an image is being prepared holds the send and sends the composer once it joins (ComposerController `sendAfterPreparing`) |
| a5090a7576 | #38684 | composer | fix(web): Default effort no longer shows as the lowest bar | ported: ComposerEffortGlyph names Default |

## Small fixes, connections (46)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| e6ca17001d | #26917 | connections | fix(web): update everything no longer waits on npm for service hosts | left (panels-4): Update everything lives in Features/Updates and Settings, outside this pass; service hosts skip the npm wait (updateEverything.logic.ts) |
| de386ada9e | #23244 | connections | fix(web): create tasks on a permitted connected environment | left (panels-4): scheduled tasks environment choice, held for the Settings agent (ScheduledTasksSettings) |
| 4092c4ac56 | #27008 | connections | fix(client): retry the permissions check after a reconnect | left (panels-4): the permissions note retries after a reconnect; needs a session-state reread on reconnect in ConnectionsHostViews' host (Settings agent) |
| 65b0ab8c91 | #27101 | connections | fix(client): dead connection routes are probed 30x less often | already in CandyWrapper (panels-4): silent routes back off from 2 to 30 minutes (connection-2, Environments.routeBackoff) |
| ebd1265ccf | #21706 | connections | fix(connect): the remove dialog says whether a T3 Connect environment is still on the account | left (panels-4): the T3 Connect remove dialog wording, held for the Settings agent |
| 503bcaaf99 | #22887 | connections | fix: keep offline environments out of thread reorder writes | left (panels-4): offline environments in thread reorder writes, held for the Sidebar agent |
| b1b3c10e24 | #23532 | connections | fix(clients): keep accepted server updates through disconnects | left (panels-4): Update everything lives in Features/Updates and Settings, outside this pass; accepted updates survive disconnects (outdatedHostUpdate.ts) |
| fd78ea42fc | #23753 | connections | fix(web): show an error when merge-back or disconnect fails | left (panels-4): merge-back and disconnect errors in the relationships control, held for the Thread agent |
| e5871b6719 | #24691 | connections | fix(web): Reconnect on a switched-off environment switches it back on | left (panels-4): Reconnect on a switched-off environment, a composer banner, held for the Composer agent |
| 9e97921ad8 | #24716 | connections | fix(clients): a route added after a reorder no longer disappears | left (panels-4): route reorder in the routes list, held for the Settings agent |
| d2d1e4f50e | #27847 | connections | fix(updates): version checks respect your configured npm registry | left (panels-4): Update everything lives in Features/Updates and Settings, outside this pass; npm registry for version checks is server side; CW reads the result |
| a05e8fde08 | #26160 | connections | fix(web): Add Environment dialog reopens on Remote link instead of a stale SSH selection | left (panels-4): Add Environment dialog mode reset, held for the Settings agent |
| 1aa46d0cdf | #27998 | connections | fix(connect): T3 Connect sockets no longer drop every hour | already in CandyWrapper (panels-4): T3 Connect sockets renew their token in the last minute (connection, T3ConnectAuthorizer.swift:310-338) |
| 8f0d66de5f | #26109 | connections | fix(web): servers still restarting after an app update no longer offer the update again | left (panels-4): Update everything lives in Features/Updates and Settings, outside this pass; servers restarting after an update |
| 7cd9a73b2f | #24493 | connections | fix(web): thread alerts missed during a disconnect fire on reconnect | ported (panels-2): a stale shell pauses its environment's tracker instead of forgetting it, so what changed during the disconnect notifies once on reconnect |
| aa46f7ada4 | #25591 | connections | fix(client-runtime): re-pairing at a new address uses the new token | ported (panels-4): a route paired at a new address goes first among its kind (EnvironmentRoute.upsert, connection/routes.ts:159-169) |
| 95d4da5a93 | #28592 | connections | fix(clients): open a delegated child's approval on the environment it runs in | already in CandyWrapper: the child input banner opens the child's scoped thread id, which carries its own environment (Features/Thread/ThreadLineageController `updateChildInputs`) |
| 322f6544df | #30498 | connections | feat(web): show a newly created pairing link without expanding the client list | left (panels-4): new pairing link shown without expanding, held for the Settings agent |
| d520d5bb85 | #26464 | connections | fix(web): show saved service access with Local environment off | left (panels-4): saved service access with Local off, held for the Settings agent |
| dff0b1159b | #25198 | connections | fix(connect): show why relay unlink failed | left (panels-4): relay unlink failure reason, held for the Settings agent |
| 7fe1310ee5 | #32937 | connections | fix(web): Copy MCP URL uses the T3 Connect address | left (panels-4): Copy MCP URL uses the T3 Connect address; needs presentation.ts's route choice in the Settings MCP row |
| b5256ad09c | #22839 | connections | fix(opencode): verify CLI updates when loopback server is still running | free with the runtime (panels-4): OpenCode CLI update verification is server side |
| 25f4c9d44e | #23194 | connections | fix(web): offer retry while an environment reconnects | left (panels-4): retry while reconnecting, a composer banner, held for the Composer agent |
| ba32aabf62 | #23111 | connections | fix(scheduler): show short server timezone on fixed-time labels | left (panels-4): short server timezone on scheduled task labels, held for the Settings agent |
| 54a5c51a58 | #21530 | connections | fix(web): fall back to a readable server for shared repositories | left (panels-4): PR list falls back to a readable server for shared repositories; same work as #34088 in PullRequestsPage |
| 42d645ae9e | #32924 | connections | fix(web): update Retry stops re-sending servers already on the target version | left (panels-4): Update everything lives in Features/Updates and Settings, outside this pass; Retry skips servers already on the target |
| 7eca0ed885 | #29462 | connections | fix(web): hand-started t3 servers get an update command that updates them | left (panels-4): Update everything lives in Features/Updates and Settings, outside this pass; hand-started servers' update command |
| 6790f85f53 | #27692 | connections | fix(web): point pairing copy at Sharing & access | left (panels-4): pairing copy points at Sharing & access, held for the Settings agent |
| fa9d85fad5 | #35327 | connections | fix(web): a server updated with the app reconnects as soon as it is ready | n/a (settings-3): CandyWrapper has no relaunch handoff of server updates; ServerUpdater.run already retries the connection every second while a server restarts |
| 00f617db4e | #24400 | connections | fix(client-runtime): recover subscriptions that stop on a healthy connection | already in CandyWrapper (panels-4): a stream that fails on a healthy socket resubscribes with backoff (ConnectionSupervisor.swift:937-956) |
| cbf0f0a83f | #36445 | connections | fix(web): screen readers read the Update everything machine list as a table | n/a (panels-4): an ARIA table role; CW's Update everything list is native AX rows |
| 757f71a7f6 | #29788 | connections | fix(client-runtime): new T3 Connect machines appear without signing in again | left (panels-4): refresh the T3 Connect machine list on app activation; Environments.swift:94 checks routes only |
| bd9ff7eb2a | #33244 | connections | fix(client-runtime): recover thread list updates after stream defects | already in CandyWrapper (panels-4): the thread list stream resubscribes after a bad value (ConnectionSupervisor.swift:950-956) |
| ca7a9448b8 | #24932 | connections | fix(client-runtime): Reconnect works while the network reports offline | already in CandyWrapper: connection-2 made Reconnect work while the device reports offline (ConnectionSignalTests) |
| efae4e9da1 | #36559 | connections | fix(client): retry unread thread visits after reconnect | left (panels-4): ThreadSession.swift:1347-1394 drops a failed thread.visit; retry it on the next connection (ThreadSession, outside these areas) |
| ead133ce70 | #28297 | connections | fix(web): SSH port field no longer turns 22.5 into port 22 | already in CandyWrapper (panels-4): Swift Int() rejects 22.5 (SshEnvironmentTarget.manual) |
| acd192fc64 | #36726 | connections | fix(web): removing an environment dismisses its notification toasts | left (panels-4): removing an environment dismisses its toasts; ThreadNotificationCoordinator, outside these areas |
| 12102c74a3 | #28907 | connections | fix(web,mobile): Linked environments shows links made outside the app | left (panels-4): links made outside the app in Linked environments, held for the Settings agent |
| 5583b26460 | #36793 | connections | fix(server,client): preserve literal JSON command output | left (panels-4): literal JSON command output; needs commandOutput.ts's raw text path in T3Store CommandOutputBuffer, checked with a transcript |
| a6765d41d5 | #33795 | connections | fix(web): audio and server spinners respect reduced motion | already in CandyWrapper (panels-4): SpinnerView holds a still arc under Reduce Motion (DesignSystem SpinnerView.swift:5), which ThreadServersView uses |
| e1458f25e2 | #32048 | connections | fix(web): track switch no longer blocked when Local environment is off | left (panels-4): Update everything lives in Features/Updates and Settings, outside this pass; track switch with Local off |
| 1672b51630 | #32157 | connections | fix(web): Add Environment drops the old tab's error when switching mode | left (panels-4): Add Environment drops the old tab's error, held for the Settings agent |
| 399ea10f4e | #37490 | connections | fix(web): Update everything no longer offers a Nightly build to a Stable desktop app | ported (settings-3): UpdateEverythingLogic.serverTargets skips a Stable desktop host for a Nightly target |
| 27411651a4 | #37825 | connections | fix(auth): bind automatic pairing codes to peer links | free with the runtime (panels-4): server-side pairing code binding |
| c48825322d | #38442 | connections | fix(web): pairing links never use the desktop app's t3code:// address | left (panels-4): pairing links never use t3code://, held for the Settings agent (AuthorizedClientsSettings) |
| dcaff67177 | #38980 | connections | fix(web): removing a connection withdraws its permission update notice | left (panels-4): removing a connection withdraws its permission notice; ThreadSession's permission notice, outside these areas |

## Small fixes, device (10)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| a3df6044a4 | #21430 | device | fix(web): preserve the active pointer in the flat Device view | already in CandyWrapper (panels-3): AppKit sends every drag to the view that took the mouse-down, so DevicePanelStreamView keeps the touch (DevicePanelView.swift:255-261) |
| 9bd5e12242 | #24106 | device | fix(web): restored Device view waits for device state before setup | skip (panels-3): restoring a Device view needs a live device host to check; the sandbox has no simulator runtime or Android SDK (parity-checklist Device panel) |
| 43b56b1790 | #23339 | device | fix(device): forward numeric keypad keys to iOS simulators | ported (panels-3): the numeric keypad's keys map to HID usages 0x54-0x63 and 0x67 on iOS, DevicePanelStreamClient.key |
| 09ace626bb | #28323 | device | fix(web): device tools keep the typed text when a command fails | already in CandyWrapper (panels-3): DeviceToolsDrawerView never clears a field after a command, so a failure keeps the text; T3 also clears it after success, which CW does not |
| a821f039c1 | #29352 | device | fix(client-runtime): connection diagnosis no longer blames the host while this device's sign-in loads | left (panels-3): diagnosis while this device's sign-in loads lives in Features/Settings ConnectionDiagnosis.swift, held for the Settings agent |
| 3ee55151e0 | #29912 | device | fix(web): device host checks show the error without a stack trace | n/a (panels-3): CandyWrapper shows the server's message for a host check, never an Effect cause with a stack |
| 202d5b5616 | #25971 | device | fix(devices): keep devices listed when simulator discovery fails | skip (panels-3): the discovery warning popover with Retry needs a device host whose discovery fails to check; the sandbox has no device runtime |
| f475de2f75 | #27030 | device | fix(web): device tool update buttons fit their popovers | n/a (panels-3): CandyWrapper has no device tool update buttons yet (parity-checklist Device tools drawer, tool versions remain) |
| aa37097093 | #35664 | device | fix(web): streamed device toolbar starts at the panel size | n/a (panels-3): a streamed browser tab in CandyWrapper sizes from its own view's bounds, not a published panel rect |
| 9e32c95576 | #33199 | device | fix(client-runtime): show routes whose host refused this device's sign-in | left (panels-3): routes a host refused this device's sign-in need the connection driver's refusal state and Settings EnvironmentRoutesList, held for the Settings agent |

## Small fixes, diff (18)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 456892da72 | #23723 | diff | fix(web): show rounded diff counts as 1m instead of 1000k | ported (panels-2): DiffStatView.compact rounds 999,500 up to 1m |
| 80a2351fcb | #25865 | diff | fix(web,mobile): Luau files are syntax highlighted in diffs | left (panels-2): add luau to lua and xsl, xslt to xml in Features/Markdown/CodeHighlighter.swift, which another agent holds |
| dc9b1a5a63 | #27635 | diff | fix(web): keep diff base selector available after errors | ported (panels-2): the Changes head and base selector stays after a failed read, HEAD and Automatic as fallbacks |
| 5651d76818 | #28091 | diff | fix(web): horizontal scrolling inside diff and file panes no longer switches threads | left (panels-2): goes with the history-swipe group (#30173) outside the diff views |
| 1c0cc439ff | #28386 | diff | fix(web): deleting a thread clears its saved right-panel, diff-panel and mini-player state | skipped (panels-2): CandyWrapper keeps panel and diff selection per open thread in memory; only the diff base choice persists (DiffPanelView baseRefsKey), and clearing it needs the delete path in Features/Sidebar |
| 300101f7e5 | #29309 | diff | fix(web): open files from Claude and ACP tool-call diffs | skip (panels-3): CandyWrapper's diff file headers offer no Open or Reveal (DiffPanelView.onOpenFile is unset in the app); port with that action |
| 8b44f42b14 | #30567 | diff | fix(web): load selected diff metadata before file patches | n/a (panels-2): CandyWrapper reads the whole patch, with no metadata-first file list |
| 996b43f01b | #22347 | diff | fix(web): retain diff selection across navigation | left (panels-2): diff selection across navigation lives in Features/Thread ThreadPanelView |
| bd02e64b5f | #28056 | diff | fix(web): expanding a diff whose files changed no longer crashes | n/a: React render crash |
| e5b5da3a7c | #27550 | diff | fix(web): reopening a guide with many cached diff pages no longer crashes | n/a: React render crash |
| f39c4405fa | #35090 | diff | fix(web): diff tab keeps its scroll position across thread switches | left (panels-2): scroll position per thread needs ThreadPanelView to keep the DiffListView offset |
| fbd77b9b37 | #28947 | diff | fix(web): diff colors follow appearance contrast | left (panels-2): DiffStyle's addition and deletion mixes need the appearance contrast boost (calc(N% - boost/4)) |
| a621be8d15 | #35922 | diff | fix(web): open code blocks and diffs follow a changed word wrap default | ported (panels-2): the wrap toggle follows a changed wordWrap default until pressed |
| 953ce60d12 | #36606 | diff | fix(web): changed root files with a leading space open in the diff panel | already in CandyWrapper: DiffPanelView.open passes the file path untrimmed |
| bef412cff6 | #33310 | diff | fix(web): diff file tree shows added and deleted files before their patches load | n/a (panels-2): CandyWrapper reads the whole patch, so files and change types arrive together |
| b96a511067 | #35304 | diff | fix(web): repeated diff blocks no longer crash the viewer | n/a: React key crash |
| 2b6c14bbf1 | #23167 | diff | fix(web): diff file Open and Reveal reach a file whose name has a backslash | skip (panels-3): needs the diff header's Open and Reveal, which CandyWrapper lacks; port with that action |
| 9a79883979 | #32684 | diff | fix(web): a file opened from a diff in a project folder inside a repository opens that file | skip (panels-3): needs the diff header's Open and Reveal, which CandyWrapper lacks; port with that action |

## Small fixes, files (22)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| de2b1d3358 | #23745 | files | fix(web): keep HTML prototype selection rings visible | n/a (panels-3): HTML prototype selection rings belong to T3's design-mode overlay, which CandyWrapper's HTML preview does not have |
| f06dd4bbf5 | #25737 | files | feat(web): allow resizing the file explorer | left (panels-3): a resizable Files tree needs a drag handle in FilesPanelView between tree and file (160-560pt, file at least 256pt) |
| 78f1ba8285 | #25555 | files | fix(web): preserve PDF scroll and zoom across autoreloads | skip (panels-3): PDFs open in Quick Look in CandyWrapper, which keeps its own scroll and zoom |
| 461df465ab | #26579 | files | fix(web): file context menu actions respond to pointer clicks | n/a (panels-3): base-ui pointer handling; CandyWrapper's context menus are AppKit menus |
| 433bff1e30 | #28521 | files | fix(web): clicking a file in the Files tree keeps focus on that row | left (panels-3): not checked on screen; a clicked file row should keep keyboard focus in FileTreeView |
| 09647d188d | #30601 | files | fix(shared): CSV and TSV attachments keep their table under generic file types | already in CandyWrapper: FilePreviewKind.of picks the table from the .csv or .tsv extension, whatever the MIME type |
| 9ef52de293 | #23203 | files | fix(shared): keep spreadsheet shorthand as inline code | left (panels-3): spreadsheet shorthand staying inline code is FileLinks.inlineCodeCandidate in Features/Markdown, held for the Markdown agent |
| 1ab3afe892 | #34360 | files | fix(web): opening a file focuses its editor so Cmd+F searches it | left (panels-3): focusing the opened file's code view so Cmd+F searches it needs a first-responder hand-off in FileSurfaceView |
| eceeab4d5c | #34346 | files | fix(web): Cmd+F in the Files panel focuses its search | left (panels-3): Cmd+F in the Files panel focusing its search needs the panel's find shortcut routed to FilesPanelView's search field |
| f10a5029f5 | #35067 | files | fix(web): Files tree keeps expanded folders across remounts | left (panels-3): keeping expanded folders across remounts needs FileTreeModel's expanded set stored per environment and cwd |
| 08544ba3e5 | #32693 | files | fix(web): open documents no longer reload after every agent command | left (panels-3): not checked whether FilesController reloads open documents after agent commands |
| 8cb551a3ce | #36664 | files | fix(web): saved files show external edits after a failed reload | left (panels-3): showing external edits after a failed reload needs CodeFileView's saved state checked against FileSaveFailureTests |
| 8b633d9a9e | #29802 | files | fix(web): PDF find matches curly quotes when you type straight ones | skip (panels-3): PDF find runs in Quick Look in CandyWrapper |
| f05cd350d2 | #29996 | files | fix(web): opening a very large folder no longer freezes the Files panel | already in CandyWrapper (panels-3): FileTreeModel caps expandable ignored folders (expandableDirectoryPaths) and the tree is virtualized |
| 2afee52025 | #33125 | files | fix(web): distinguish media Back from window close | skip (panels-3): media open in Quick Look in CandyWrapper, which has its own close |
| 5f80af6805 | #36936 | files | fix(web): restore word selection in inline code | left (panels-3): word selection in inline code is Features/Markdown, held for the Markdown agent |
| 71adeef080 | #37064 | files | fix(web): open PDF links in the file viewer | skip (panels-3): PDF links open in Quick Look in CandyWrapper |
| 109e9dbdfd | #37361 | files | fix(web): file tabs keep their scroll position when you switch back | left (panels-3): keeping a file tab's scroll position needs FileSurfaceView to store each path's scroll offset when it hides |
| 6dd092315e | #31785 | files | fix(web): file tree icons and ignored rows follow the theme's muted text | ported (panels-3): the tree's chevrons, guides and ignored rows take the theme's contrast muted text, FilesPanelView |
| f4d0855a50 | #33805 | files | fix(web): PDF attachment chips no longer look like failed ones | skip (panels-3): PDF chips hand off to Quick Look in CandyWrapper; the chip look is the composer's |
| 0d405f664a | #38510 | files | fix(web): a ~\ home path opens as a read-only home file, not as a project file | left (panels-3): a ~\\ home path needs FilesLogic's relative path split to read ~\\ as home |
| e48d6f3181 | #38749 | files | fix(web): PDFs in the desktop file panel can be saved again | skip (panels-3): PDFs open in Quick Look in CandyWrapper, which saves them itself |

## Small fixes, issues (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 0c676d95b1 | #38160 | issues | fix(web): screen readers name thread details issue and PR rows by number and title | left (panels-2): not checked |
| 05e3674636 | #38995 | issues | fix(web): screen readers read a linked issue's key once in thread details | left (panels-2): not checked |

## Small fixes, palette (4)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 1cfd23e7cb | #25236 | palette | fix(web): keep palette project lookups in their environment | already in CandyWrapper (panels-3): ProjectId carries its environment, so PaletteCommands looks projects up per environment |
| 977d613611 | #29288 | palette | fix(web): command palette footer hints wrap instead of clipping on narrow viewports | n/a (panels-3): the palette is a fixed 576pt panel and the window's 840pt minimum (MainWindow.swift:40) keeps its hints on one line |
| b732621b51 | #37315 | palette | fix(clients): command palette skips tasks shown under their parent | already in CandyWrapper (panels-3): PaletteCommands drops threads with !lineage.isListed, which includes delegatedUnderParent (ThreadShell.swift:279) |
| e0f5acd178 | #38968 | palette | fix(web): the command palette lists a failed thread as Failed, not Waiting | ported (panels-3): a failed run outranks background work's Waiting, SidebarModel.resolveThreadStatusPill, shared by the palette and the sidebar |

## Small fixes, pr/git (161)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 5b89a53585 | #25588 | pr/git | feat(pull-requests): manage GitHub maintainer edits | ported (panels-2): "Allow edits from maintainers" checkbox in the ⋯ menu, `pullRequests.update` `maintainerCanModify`; the hint wraps at 320pt with "Saving…" under it (panels-3, MenuItem.subtitleWrapWidth) |
| 9d38d68d04 | #23225 | pr/git | fix(web): wait for fresh diff pages in review guides | n/a (panels-3): CandyWrapper has no review guide view, only its settings rows |
| a8d6b0e66b | #22522 | pr/git | fix(web): mouse Back/Forward over a streamed preview navigate the preview | ported (panels-3): the mouse's back and forward buttons over a streamed tab move its history, with #30882 (ServerBrowserView.onThumbNavigate) |
| 1c99a55444 | #23577 | pr/git | fix(web): report invalid preview addresses | ported (panels-4): an address the browser can't open shows "Could not open this address" (BrowserController.invalidAddress) |
| 13f9bc4e55 | #23678 | pr/git | fix(web): label inherited worktree cleanup modes correctly | left (panels-4): Settings inheritance labels for worktree cleanup, held for the Settings agent |
| be43da4c0d | #23732 | pr/git | fix(web): PDF previews keep their page when the agent responds | skip (panels-3): CandyWrapper hands this format to Quick Look |
| 3e7277e7e8 | #23742 | pr/git | fix(web): release discarded draft image previews after Undo expires | n/a (panels-4): releases browser object URLs; CW holds no object URLs for draft images |
| 64968b3109 | #24060 | pr/git | fix(web): a branch restore in one thread no longer blocks another thread | left (panels-4): per-thread branch restore lives in ChatView's thread lifecycle, held for the Thread agent |
| bc216e4675 | #24081 | pr/git | fix(web): closed preview sessions no longer keep syncing for the rest of the session | already in CandyWrapper (panels-4): a preview tab streams only while its panel or the mini player shows (BrowserController.swift:12, 33) |
| e9dd8a68ee | #24117 | pr/git | fix(clients): offer Commit when the branch is behind upstream | ported (panels-4): changes on a branch behind upstream offer Commit (GitActionsLogic.quickAction) |
| c9246445e0 | #24189 | pr/git | fix(web): long guide Next buttons wrap instead of overflowing | n/a (panels-3): CandyWrapper has no review guide view, only its settings rows |
| f5bc64b7b7 | #24489 | pr/git | fix(web): deleting a thread no longer offers to remove a shared worktree | left (panels-4): thread delete worktree prompt, held for the Sidebar agent |
| 9474bcbae1 | #25303 | pr/git | fix(web): preserve trailing whitespace in review diffs | already in CandyWrapper (panels-4): UnifiedDiff keeps each line's text as sent, trailing whitespace included |
| e428a2c1f5 | #26060 | pr/git | fix(web,mobile): pull request text breaks lines when providers do | ported (panels-4): PR descriptions keep single line breaks on GitHub, Forgejo and Azure DevOps (PullRequestDetailLogic.hardLineBreaks); comment bodies still need the provider threaded into CommentCard and ConversationRow |
| 4dd2f735f2 | #26441 | pr/git | fix(web): Load balancing and PR sharing name the route in use | left (panels-4): Load balancing and PR routing settings rows, held for the Settings agent |
| 6e72f540f6 | #26563 | pr/git | fix(prs): classify generated files and evals correctly | ported (panels-3): ChangedFileKind follows 4928's generated and evals rules for the hide-tests filter; the PR breakdown itself comes from the server |
| 3a873e8faf | #23475 | pr/git | fix(web): disable conflict checkout without required permissions | left (panels-4): conflict checkout needs the canPrepareWorktree permission, which CW's PR panel doesn't read yet |
| a2e4524d51 | #21579 | pr/git | fix(web): preview address bar no longer ligates "://" | n/a (panels-3): the address field draws with the UI font, which has no "://" ligature |
| e123ac644e | #26073 | pr/git | fix(web): a failed review guide keeps Try again reachable | n/a (panels-3): CandyWrapper has no review guide view, only its settings rows |
| 7cdbb8ef59 | #27114 | pr/git | fix(web): show the worktree picker in the composer strip at default width | ported (composer-5): from a 576pt composer the default themes' strip shows the machine, a separator and the workspace picker on the left and the branch at the end; the workspace menu then lists workspaces only. Spec case run-on `strip.git.wide` (2.58 to 2.92%) and a layout test |
| 45d29b45fe | #22382 | pr/git | fix(web): a refused review shows GitHub's reason | ported (panels-4): a refused review shows the host's reason (PullRequestDetailLogic.readableFailure) |
| 1c8ada5023 | #22974 | pr/git | fix(web): composer notices no longer flicker next to a floating preview | n/a (panels-3): React render flicker |
| a24ec905c8 | #28070 | pr/git | fix(web): machine label no longer shifts between one and many machines | left (panels-4): BranchToolbar environment label, composer strip, held for the Composer agent |
| 793bbf47b3 | #28077 | pr/git | fix(web): long titles no longer overflow the pull request list tooltip | n/a (panels-4): a web tooltip max width; AppKit tooltips wrap on their own |
| 78aa0d5ca5 | #27925 | pr/git | feat(mcp): unlink every PR in given states with one call | n/a: T3's MCP tools, which run on the server |
| 01bd0a2702 | #27994 | pr/git | feat(mcp): link several PRs to a thread with one call | n/a: T3's MCP tools, which run on the server |
| 43d445b408 | #21839 | pr/git | fix(web): file preview videos keep their own aspect ratio | already in CandyWrapper (panels-4): file preview videos play in AVPlayerView, which keeps the aspect ratio (FileSurfaceView) |
| 85133dc578 | #23129 | pr/git | fix(web): PR diffs list a `.logic.test.ts` file beside the source it covers | left (panels-4): CW lists PR files in host order; needs T3's import-ordered orderDiffFiles (pullRequestFileOrder.logic.ts:142) first |
| 3331b93937 | #23156 | pr/git | fix(web): show linked pull request state in command palette rows | left (panels-4): command palette thread rows, outside these areas |
| 665351fc39 | #24118 | pr/git | fix(web): show readable errors when a stack action fails | ported (panels-4): stack merge and rebase failures show the host's reason or what usually stops each (PullRequestsController) |
| 9ff0fac0f4 | #28244 | pr/git | fix(web): make Changes and PR Code file lists resizable | left (panels-2): resizable Changes and PR Code file lists, 5.1 |
| b50d8a1b15 | #28573 | pr/git | fix(web): add spacing above PR detail metadata | left (panels-4): ThreadDetailsPrRow metadata spacing; the row has no component reference to check mt-1.5 against |
| 82b10d546c | #28665 | pr/git | fix(web): align pull request file viewed checkboxes | ported (panels-4): the Viewed tick sits in a fixed 72pt box so Viewed and Changed line up (DiffRowViews FileHeaderRow) |
| f482dc5c57 | #25496 | pr/git | fix(web): PDF previews keep their page across thread switches | skip (panels-3): CandyWrapper hands this format to Quick Look |
| 5b5bd169e0 | #26077 | pr/git | fix(web): PR merge buttons stay in place while the stack loads | left (panels-4): auto-merge stays in place with mergeBlockedReason while the stack loads; needs the stack-loading state in PullRequestDetailView's merge row |
| 7816a0fa81 | #27434 | pr/git | fix(web): Enter selects the first branch search result | already in CandyWrapper (panels-4): a query highlights the first enabled branch, so Enter picks it (BranchPickerView.swift:123) |
| 716e1c071c | #28439 | pr/git | fix(web): Changes row no longer shows +0 while Diff has edits | ported (panels-4): zero branch totals fall back to the working tree (GitActionsLogic.changesTotals) |
| dd6c05ec31 | #28613 | pr/git | fix(preview): agent browser use no longer steals composer focus | n/a (panels-4): Electron webview focus juggling; CW's browser is a WKWebView in the panel |
| 4a5251b1c4 | #29005 | pr/git | fix(web): keep pending pull request actions scoped to each request | left (panels-4): per-request pending keys for PR actions; CW keeps one pending flag per open detail (PullRequestsController) |
| 1d80d0e215 | #27438 | pr/git | fix(client-runtime): branch picker shows branches changed outside T3 Code | already in CandyWrapper (panels-4): the branch picker reads vcs.listRefs fresh on every open and query, with no cache (GitController.swift:719) |
| 4494faa270 | #29161 | pr/git | fix(client-runtime): checking out a pull request refreshes cached branch lists | already in CandyWrapper (panels-4): CW caches no branch lists, so a checkout has nothing stale to refresh |
| 523145993e | #29575 | pr/git | fix(web): review comments keep a trailing blank line in their diff | left (panels-4): review comment context in the composer, held for the Composer agent |
| f2513bd288 | #23641 | pr/git | fix(web): project settings can set a checkout's grouping rule again | left (panels-4): project settings grouping rule, held for the Settings agent |
| 16fd1a440e | #25064 | pr/git | fix(web): match new-thread hero to selected checkout | left (panels-4): new-thread hero headline, held for the Thread agent |
| 6e58094f74 | #23396 | pr/git | fix(preview): explain invalid URLs and locators | free with the runtime (panels-4): server-side preview error text |
| ea68f2a667 | #29908 | pr/git | fix(web): picking a branch in a subfolder project keeps the thread in the project folder | left (panels-4): subfolder project checkout match in the branch picker needs the project's checkout root read (BranchToolbar.logic.ts) |
| c185d780fc | #29655 | pr/git | fix(preview): a dropped stream withdraws its stale file picker | already in CandyWrapper (panels-4): a dropped stream clears the file picker (BrowserController.swift:464-468) |
| 48e73f6ca9 | #29360 | pr/git | fix: honor generic MIME aliases in attachment previews | left (panels-4): MIME aliases in attachment previews, held for the Composer agent |
| b3041a8cb9 | #28832 | pr/git | fix(web): show Setting up during worktree setup | ported 9a0153d1 |
| 199cb5b6a9 | #30085 | pr/git | fix(web): show the comparison base beside Changes totals | ported (panels-4): the Changes row shows Uncommitted or vs <base> beside its totals (DetailsRowControl.detail, GitActionsLogic.changesBaseLabel) |
| 7384cf20da | #30704 | pr/git | fix(web,mobile): save pull request description checkbox changes | left (panels-4): ticking a task checkbox in a PR description saves it; needs interactive checkboxes in MarkdownView, held for the Markdown agent |
| e4b98f9d39 | #21631 | pr/git | fix(assets): preserve the PR repository for GitHub media | left (panels-4): GitHub media keep the PR repository; needs the PR media asset route CW doesn't use yet |
| 444921eb71 | #30483 | pr/git | fix(gitlab): merge requests can edit their labels | free with the runtime (panels-4): GitLab label edits are server side; CW's label picker already sends them |
| d929e726f2 | #31741 | pr/git | fix(pr): GitCafe attachments render in pull request bodies | left (panels-4): GitCafe attachment rendering in PR bodies, needs the PR media rewrite (pullRequestMarkdown.ts) |
| c52df24d28 | #22489 | pr/git | fix(prs): reviewer menu searches past the first page and keeps GitLab's requested reviewers | ported (panels-2): the reviewer picker asks the host with `query` past a truncated page where `reviewers.searchCandidates`, with T3's four truncation notes |
| 4821696509 | #30352 | pr/git | fix(client-runtime): pull request bodies with CRLF line endings keep their code blocks whole | left (panels-4): CRLF normalisation of PR bodies before markdown parse (pullRequestMarkdown.ts); one line in PullRequestTabs once checked against MarkdownDocument |
| e5193ac0a2 | #30345 | pr/git | fix(web): preview annotation chip labels no longer end in a broken character | n/a (panels-3): CandyWrapper has no preview annotation tool |
| cae7e5cc57 | #30717 | pr/git | fix(review-guide): preserve excerpt line terminators | n/a (panels-3): CandyWrapper has no review guide view, only its settings rows |
| 0aae72244e | #31814 | pr/git | fix(web): keep change totals aligned beside the label | ported (panels-4): totals stay right-aligned after the base label in the Changes row (DetailsRowControl layout) |
| 0a2f59056b | #31858 | pr/git | fix(web): improve Changes row text and spacing | ported (panels-4): Changes totals at the row's 13pt with an 8pt gap in the default themes (DiffTotalsView) |
| 32a0531748 | #25988 | pr/git | fix(web): PR bodies keep before/after video tables intact | left (panels-4): before/after video tables in PR bodies need HTML table and video support in MarkdownView, held for the Markdown agent |
| e74b410e29 | #29642 | pr/git | fix(web): keybinding settings recognize the previewOpen condition | left (panels-3): keybinding settings in Features/Settings, held for the Settings agent |
| 75200f45c6 | #29678 | pr/git | fix(web): thread navigation shortcuts honor previewFocus and previewOpen conditions | left (panels-4): sidebar thread navigation shortcuts, held for the Sidebar agent |
| daa6984fd6 | #30392 | pr/git | fix(web): review findings handed to a thread no longer end in a broken character | n/a (panels-3): CandyWrapper has no review guide view, only its settings rows |
| 6647b0a761 | #30812 | pr/git | fix(web): rich text previews keep paragraphs that end with a backslash | skip (panels-4): CW has no rich text document preview; Quick Look shows those files |
| 8ab427c607 | #33113 | pr/git | fix(web): settings say custom instructions cover pull request descriptions | left (panels-3): settings copy in Features/Settings, held for the Settings agent |
| a88a0adfa1 | #34003 | pr/git | fix(web): keep HTML previews anchored when accordions expand | left (panels-4): HTML preview anchoring in the timeline, held for the Thread agent |
| 44e894ffd7 | #34017 | pr/git | fix(web): preserve search result titles in drag previews | n/a (panels-3): HTML drag previews of search results; CandyWrapper drags no search results |
| 8fc6fd01d7 | #33949 | pr/git | fix(web): preserve previews during attachment preparation | left (panels-4): attachment previews during preparation, held for the Composer agent |
| d152d2c824 | #30150 | pr/git | fix(client-runtime): a search query pasted from github.com lists pull requests again | ported (panels-2): GitHub's own qualifiers (is, state, repo, org, user, sort, archived) are ignored, two different authors name none, a negated draft flips, PullRequestListLogic.parseQuery |
| 4ca10398b1 | #34140 | pr/git | fix(web): tighter outdated-conversation cards in the PR code panel | left (panels-4): tighter outdated-conversation cards; PullRequestReviewAnnotationViews has no reference case for the folded card yet |
| b3fdf2b10f | #33989 | pr/git | fix(web): PR links jump to the comment, diff line, checks or commits they name | left (panels-4): PR link jumps, see the feature list in PROGRESS |
| dea8472438 | #28732 | pr/git | feat(web): label chips show the label's description on hover | ported (panels-4): label chips show the label description on hover and to VoiceOver (PullRequestLabel.description, PullRequestLabelChip) |
| b6d3097379 | #28459 | pr/git | feat(web): composer strip names the worktree folder | ported: a started thread's strip names its worktree folder (BranchToolbarLogic `lockedWorkspaceLabel`, Features/Git) |
| 8cbc95923a | #34168 | pr/git | fix(web): files marked Viewed stay folded when a pull request's Code tab opens again | ported (panels-3): Viewed marks that load after the diff fold their files, the reader's fold wins, PullRequestCodeView.applyFolds |
| 75b22bf56c | #30620 | pr/git | fix(web): dismiss image path tooltips after preview and scroll | n/a (panels-4): web image path tooltips stuck after scroll; AppKit tooltips dismiss on their own |
| 8c9af5418a | #31972 | pr/git | fix(web): disable the git actions menu when nothing in it is usable | left (panels-4): disable the git actions menu when nothing in it is usable; needs hasUsableGitMenuContent in GitController's menu trigger |
| 1bdf470328 | #34048 | pr/git | fix(web): project actions auto-open Preview in web clients | n/a (panels-3): web clients only |
| 49bab9936e | #19553 | pr/git | fix(web): Changes row matches the diff comparison | left (panels-4): the Changes row should follow the Diff panel's branch comparison and whitespace toggle; needs the Diff panel to report its file stats to GitController |
| fcddd737e2 | #22208 | pr/git | fix(web): don't save retention age until committed | left (panels-4): storage retention field, held for the Settings agent |
| 27188274e7 | #26992 | pr/git | fix(web): pull request search keeps partial-word matches after GitHub answers | left (panels-4): PR search baseline rows; needs the text-free baseline read in PullRequestsPage |
| 479ee74135 | #15848 | pr/git | fix(web): a thread started from a pull request links it | left (panels-4): a thread started from a PR links it; needs the PR draft-thread flow (usePullRequestDraftThread) CW doesn't have |
| 7e565c510d | #34218 | pr/git | fix(git): stop new threads inheriting historical branch PRs | left (panels-4): resolveDisplayedThreadPr only shows a branch PR for the thread's own branch; GitController reads status.pr directly |
| 3a0bcba00a | #34607 | pr/git | fix(shared): GitLab merge request file and line links open that file | left (panels-4): GitLab merge request anchors; part of the PR link jumps (#33989) |
| 9411a71ec0 | #34509 | pr/git | fix(web): dismissing the pull request checkout toast stops the handoff | n/a (panels-4): CW has no PR checkout handoff toast (handoffs not ported, PullRequestsController.swift:1062) |
| 8214342385 | #32283 | pr/git | fix(web): collapsed PR comments no longer show raw HTML | left (panels-4): collapsed PR comments strip raw HTML; needs pullRequestMarkdown.logic's summary text in PullRequestTabs |
| afe0528039 | #34727 | pr/git | fix(web): keep git action loading rows at idle height | left (panels-4): git action loading row height; no reference for the loading state |
| fd033dfec3 | #34722 | pr/git | fix(web): improve Word document previews | skip (panels-3): CandyWrapper hands this format to Quick Look |
| 3a30b011c3 | #34734 | pr/git | fix(web): cancelled PR checks show a gray stop sign instead of the failed X | ported (panels-2): cancelled checks wear `octagon-x` in muted/70, PullRequestStyle.checkStatus |
| 3bd7b04544 | #34796 | pr/git | fix(web): Escape and tool keys work as soon as preview annotation starts | n/a (panels-3): CandyWrapper has no preview annotation tool |
| 0ac41eecad | #34878 | pr/git | fix(web): sidebar rows drop a branch and worktree that were deleted | left (panels-4): sidebar rows drop deleted branches, held for the Sidebar agent |
| ee90bdc940 | #34992 | pr/git | fix(web): CSV/TSV and large-text previews say "1 row", "1 column" and "1 line" | n/a (panels-3): CandyWrapper shows CSV, TSV and large text as code, with no row, column or line counts |
| abbd967c4b | #35111 | pr/git | fix(web): PR comment hover excerpts no longer end in a replacement character | already in CandyWrapper (panels-4): Swift strings cut by Character, so an excerpt never ends in half a surrogate pair |
| bf8e5e61b6 | #35066 | pr/git | fix(web): a failed page in the floating browser preview shows the error instead of a blank panel | left (panels-4): the mini player shows the unreachable page on load failure; needs PreviewUnreachable inside BrowserMiniPlayerView |
| 167d41c094 | #35376 | pr/git | fix(web): a numeric author or labels in the URL no longer crashes Pull Requests | n/a (panels-4): web URL search parsing; CW's PR filters are typed values |
| d0f9d4dcc0 | #35406 | pr/git | fix(web): sidebar draft previews show cited assistant text, not the raw link | left (panels-4): sidebar draft previews, held for the Sidebar agent |
| 55081a1f7b | #35430 | pr/git | fix(shared): thread search ignores the t3 prefix of flat temporary branches | left (panels-4): palette search prefix, held for the palette owner |
| f376f5cc1d | #32302 | pr/git | fix(web): J and K step the PR guide without clicking into it first | skip (panels-4): CW has no PR review guide |
| 5cff012416 | #35548 | pr/git | feat(web): resize rows and columns in spreadsheet previews | skip (panels-4): CW has no spreadsheet preview; Quick Look shows those files |
| 1b133107a5 | #33877 | pr/git | fix(web): a branch picked right after opening the picker no longer waits for its status read | already in CandyWrapper (panels-4): the picker's status refresh doesn't gate a pick (GitController.swift:691) |
| fa8949a28c | #29441 | pr/git | fix(web): project settings can reach each checkout on one environment | left (panels-4): project actions settings scope, held for the Settings agent |
| c00a373491 | #33903 | pr/git | fix(web): Select All then Copy in a read-only file preview copies the whole file | already in CandyWrapper (panels-4): the read-only file view is an NSTextView, so Select All then Copy takes the whole file (CodeFileView) |
| c6995622d5 | #23627 | pr/git | fix(web): branch labels keep the space before a middle-truncated name | already in CandyWrapper (panels-4): MiddleTruncateView measures the string as is, spaces included |
| e179cefe7a | #35677 | pr/git | fix(web): collapsed reasoning previews no longer split an emoji | left (panels-4): reasoning preview emoji split, held for the Thread agent |
| 5e18314b88 | #32738 | pr/git | fix(forgejo): fast-forward-only repositories can merge pull requests | ported (panels-2): `fast-forward` merge method, "Fast-forward merge" label, `mergeCapabilities["fast-forward"]` |
| afff0d3efe | #35897 | pr/git | fix(clients): answer history no longer shows provider context from review comments | left (panels-4): answer history context from review comments, held for the Composer agent |
| b80531d6fb | #36056 | pr/git | fix(web): PR Code tab previews images the host sends no patch for | left (panels-4): PR Code tab image previews for files without a patch; needs the host media URL in PullRequestCodeView |
| 31b5549f98 | #35396 | pr/git | fix(web): pull request comment tooltips follow the Time format setting | left (panels-4): PR comment time tooltips should follow the Time format setting; CW's PR rows show relative time without a full-time tooltip yet |
| 21b0b7a057 | #36104 | pr/git | fix(composer): keep reviews from different Git hosts in suggestions | left (panels-4): PR suggestions across hosts, held for the Composer agent |
| 93aaad5b45 | #36211 | pr/git | fix(web): PR conversation headers wrap instead of overflowing | left (panels-4): wrapping PR conversation headers; PullRequestReviewAnnotationViews lays the header on one line |
| fcd06873e8 | #36276 | pr/git | fix(web): removing a checkout moves its open draft to a remaining checkout | left (panels-4): project settings checkout removal, held for the Settings agent |
| b009582cc9 | #36347 | pr/git | fix(web): picking the previous branch after an outside checkout switches to it | left (panels-4): confirm a listed branch with Git before reusing a worktree (staysInActiveCheckout); needs a fresh vcs.listRefs read in GitController's switch |
| f8dc37d0b7 | #36315 | pr/git | fix(web): floating preview resize holds its shape and ends when interrupted | already in CandyWrapper (panels-4): BrowserMiniPlayerResizeView ends the drag on mouseUp and keeps its aspect |
| bc7fe11002 | #36379 | pr/git | fix(web): a new worktree thread opened during a clone bases on the real default branch | left (panels-4): resolveDefaultWorktreeBaseBranch, held for the Composer agent (worktree base picker) |
| 36f011dfb7 | #36364 | pr/git | fix(web): file links the agent cited from a checkout it cd'd into open that file | left (panels-4): file links from a cd'd checkout, held for the Thread and Markdown agents |
| 2a1caac438 | #34446 | pr/git | fix(web): NVDA browse mode reads the current thread's branch, not the previous one | n/a (panels-4): NVDA browse mode; VoiceOver reads the AX value as it changes |
| a9fd0b2511 | #36466 | pr/git | fix(web): copying a file preview selection returns the selected lines after scrolling | already in CandyWrapper (panels-4): NSTextView copies the selected range regardless of scroll |
| 34cf030e5e | #27882 | pr/git | fix(web): pull requests error names the environment that failed | left (panels-4): PR list errors should name the failed environment; PullRequestsPage keeps one failure string |
| 058eea9246 | #36171 | pr/git | fix(pr): hide unsupported GitCafe review reactions | left (panels-4): PR reaction permissions; PullRequestReactionBarView takes canReact from the detail |
| 0516493a91 | #36528 | pr/git | fix(web): align status text and tighten pull request menu spacing | left (panels-4): status text alignment across the git menu, banner and PR row; no 4928 reference for those states |
| 70be20493b | #24151 | pr/git | fix: re-ticking a file after a push no longer shows it Viewed | left (panels-4): re-ticking after a push; needs the viewed-files revision field in PullRequestDetailLogic.isFileViewed |
| 1159aa2991 | #36660 | pr/git | fix(client-runtime): preserve PR reference links across embedded media | left (panels-4): PR reference links across embedded media, part of the PR media rewrite |
| 92c91aac8f | #28095 | pr/git | fix(client-runtime): keep inherited qualifier values as PR search text | n/a (panels-4): a JS prototype lookup bug; Swift dictionaries have no inherited keys (PullRequestListLogic.reviewValues) |
| a575d45286 | #28575 | pr/git | fix(web,server): the branch label no longer flips back after a switch | left (panels-4): branch hold after a switch so the label doesn't flip back; needs BranchHold in GitController |
| 3d9aeaf757 | #36738 | pr/git | fix(shared): preview semicolon-separated CSV files as tables | ported (panels-4): CSV previews detect semicolon-separated files (DelimitedTable.csvDelimiter) |
| c342f3dec2 | #29867 | pr/git | fix(web): settled threads no longer offer a PR watch the server refuses | left (panels-4): hide the PR watch for settled threads; needs threadPullRequestCompatibility in PullRequestWatchToggle |
| 732198d3a9 | #36786 | pr/git | fix(web): a disabled Push names the real reason when there are local changes | ported (panels-4): disabled Push and Create PR name the real reason with local changes (GitActionsLogic.disabledReason) |
| 170c1f7e2d | #29845 | pr/git | fix(web): Push on the default branch no longer offers a feature branch the server rejects | ported (panels-4): Push and Create PR on the default branch say a feature branch can't be named (GitActionsLogic.featureBranchUnavailableReason) |
| 49eb9c8adc | #29871 | pr/git | fix(web,mobile): pull request project filter lists pinned projects first | left (panels-4): pinned projects first in the PR project filter, after the Sidebar agent's pin work lands |
| 69525bf895 | #33692 | pr/git | fix(web): a pull request whose title holds a numeric search ranks above description-only matches | ported (panels-4): a number in a PR title ranks as a title match (PullRequestListLogic.score) |
| 73cbc6b1ed | #35527 | pr/git | fix(web): dropdown hover fills expanded Git action rows | left (panels-4): dropdown hover on expanded git rows; no 4928 reference for that state |
| 62a51e26a4 | #34662 | pr/git | fix(web): more GitLab merge request links open their file, line or commit | left (panels-4): more GitLab anchors, part of the PR link jumps (#33989) |
| ed101ef641 | #35135 | pr/git | fix(preview): unload desktop pages before removing their tabs | n/a (panels-4): Electron page unload before tab removal |
| c041761d89 | #30107 | pr/git | fix(web,server): picking the previous branch after an agent's checkout switches back | left (panels-4): resolveConfirmedSelectedRef after an agent's checkout; same work as #36347 |
| 3808e2d77e | #30571 | pr/git | fix(client-runtime): a line of inline triple-backtick code no longer breaks media in PR descriptions | left (panels-4): inline triple-backtick lines in PR media rewrite, part of the PR media work |
| 9cd5733f58 | #34088 | pr/git | fix(web): an unreachable environment no longer hides pull requests from repositories it shares | left (panels-4): pull requests from a shared repository when one environment is unreachable; needs pullRequestProjectAssignment in PullRequestsPage |
| d6c1d17793 | #37022 | pr/git | fix(web): show drag preview inside sidebar search results | left (panels-4): sidebar search drag preview, held for the Sidebar agent |
| 3ee426272b | #37033 | pr/git | fix(web): expand viewed checkbox click area | ported (panels-4): the whole 72 by 32pt Viewed label toggles the tick (FileHeaderRow.viewedArea) |
| cc4160c813 | #32404 | pr/git | fix(web): stashed prompt previews no longer end in a broken character | left (panels-4): stashed prompt previews, held for the Composer agent |
| 559cd7d3b9 | #25346 | pr/git | fix(web): quieter Ready and Merge buttons on PR rows | left (panels-4): quieter Ready and Merge buttons in ThreadDetailsPrRowView; no 4928 reference for the row |
| aace48bfe4 | #32364 | pr/git | fix(web): PR file order follows alias imports of dotted modules | left (panels-4): import-ordered PR files, same as #23129 |
| 3a1dfb7acb | #37072 | pr/git | fix(web): HTML file previews use the current canvas color | n/a (panels-4): an iframe Canvas color; CW renders HTML previews in a WKWebView that follows the page |
| 06150a08ec | #37392 | pr/git | fix(web): No project threads in New worktree mode send without a base branch | left (panels-4): No project sends without a base branch, held for the Composer agent |
| 558790aae5 | #37498 | pr/git | fix(web): stashed prompt previews show thread mentions by name, not as raw links | left (panels-4): stashed prompt thread mentions, held for the Composer agent |
| 1f698f01d9 | #37605 | pr/git | fix: PR diffs fold Viewed files the way GitHub does, on web and mobile | ported (panels-3): `isFileDiffCollapsed` with `diffFilesCollapsed` folding all and Viewed folding otherwise, PullRequestDetailLogic |
| cd42e1a497 | #37651 | pr/git | fix(web): the PR author filter says "1 merge loaded", not "1 merges loaded" | ported (panels-4): "1 merge loaded" (PullRequestsPageView author filter) |
| 0a842b222d | #37704 | pr/git | fix(web): list each pull request once across servers | ported (panels-4): a PR several environments read lists once, first answer wins (PullRequestListLogic.partition, PullRequestsPage) |
| 15271c8d00 | #37733 | pr/git | fix(pr): label and reviewer pickers send picks once, when they close | left (panels-4): label and reviewer pickers should send once on close; PullRequestCandidatePickerView sends per toggle |
| 9b313f2f09 | #37827 | pr/git | fix(composer): open PR completion after opening brackets | left (panels-4): PR completion after brackets, held for the Composer agent |
| 26f70e72fa | #37853 | pr/git | fix(web): a failed reaction toggle no longer clears a newer reaction choice | left (panels-4): a failed reaction toggle keeps a newer choice; needs per-toggle pending entries in PullRequestReactionBarView |
| 47c95c2812 | #37864 | pr/git | fix(web): a rewritten review guide no longer shows code from the previous push | skip (panels-4): CW has no PR review guide |
| ed80c2fe66 | #29658 | pr/git | fix(web): screen readers name the file checkboxes in the commit dialog | ported (panels-4): the commit dialog's file checkboxes say "Include <path>" and "Include all files" (GitDialogs) |
| e9d5bae5cf | #37881 | pr/git | fix(web): linked PR comment highlight keeps its full outline | left (panels-4): linked comment highlight outline, part of the PR link jumps (#33989) |
| d848e4b2b2 | #26566 | pr/git | fix(web): show the change breakdown on the floating Changes button | left (panels-4): the change breakdown on the floating Changes button; needs ChangeBreakdownGrid, no reference yet |
| 5b91a5a00e | #37950 | pr/git | fix(web): HTML file previews no longer flash white after agent commands | n/a (panels-4): a web iframe white flash; CW's WKWebView keeps the page between commands |
| 6ec1d31b1e | #36624 | pr/git | fix(web): preserve literal XML declarations in EPUB previews | skip (panels-4): CW has no EPUB preview; Quick Look shows those files |
| f98249acad | #38004 | pr/git | fix(web): unsaved PR review comments survive a light/dark switch | already in CandyWrapper (panels-4): pending review comments live in the composer model, which a theme switch keeps (PullRequestComposerView) |
| f92c5e8f98 | #38276 | pr/git | fix(web): review summary line comments keep which side they refer to | left (panels-4): the before side in review summaries belongs to the PR handoff prompts, not ported (PullRequestsController.swift:1062) |
| f5f8c8d18b | #38470 | pr/git | fix(web): opening a file in the preview browser shows its current contents | left (panels-4): opening a file in the preview browser with refresh, BrowserController's open-file path |
| 75514dfa55 | #38517 | pr/git | fix(web): keep Ready pending label until its request finishes | left (panels-4): keep Ready pending until done; needs the pending action name in ThreadDetailsPrRowView |
| 523a98447e | #38858 | pr/git | fix(web): files under "Also in this stop" in a review guide can be commented on | skip (panels-4): CW has no PR review guide |

## Small fixes, settings (112)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 80ae9b5301 | #23223 | settings | fix(web): show theme conflicts even when another import fails | port |
| bae3c1962c | #23160 | settings | fix(settings): offer Use existing CLI in managed Codex settings | port |
| 08a463e299 | #24472 | settings | fix(settings): project edits keep overrides the client does not know | port |
| c8a606c7b7 | #27316 | settings | fix(shared): durations under 10s drop a trailing .0 | ported (settings-3): diagnostics durations and CPU time drop a trailing .0 |
| 305a90dce4 | #27442 | settings | fix(relay): show the account's real tunnel cap in T3 Connect settings | left (settings-3): needs the #26369 meter first: RelayClient GET /v1/client/t3chat-link, managedTunnelCap with maxTunnelsOverride (managedRelayState.ts:156-172), TunnelUsageMeter and TunnelLimitAlert in Connections |
| 94b80eaf4f | #22455 | settings | fix(web): language dialects use their base language's icon | port |
| 6b276f5c40 | #22867 | settings | fix(web): project removal says provider sessions are kept | port |
| e4926868da | #22906 | settings | fix(web): diagnostics cards use one border radius | port |
| c65e488359 | #23427 | settings | fix(web): save settings fields only after an edit | port |
| 6ad082745a | #23450 | settings | fix(web): name inherited background activity profiles | port |
| 4ce9205d1f | #23465 | settings | fix(web): support Home and End on hue sliders | port |
| 6c703e1c94 | #23746 | settings | fix(web): allow Antigravity installation while status loads | port |
| 975059a718 | #23847 | settings | fix(web): keep unsaved edits to other ACP providers | port |
| 64f30421d5 | #24488 | settings | fix(web): closing an invalid When editor no longer leaves Save disabled | port |
| 49f51e1c3c | #25014 | settings | fix(web): allow adding the displayed provider accent color | port |
| f8278d8516 | #25131 | settings | fix(web): keep typed Settings text when Esc closes Settings | port |
| 1c7cef2adf | #26399 | settings | fix(web): onboarding pairing hint no longer suggests npx t3 serve --tailscale | port |
| 77f08e6b01 | #27157 | settings | fix(web): app shortcuts wait while a confirmation dialog is open | port |
| be5a887b93 | #27899 | settings | feat: add assembly file highlighting and language selection | port |
| de6d4bfead | #26335 | settings | fix(web): keep retention controls stable while editing days | port |
| ea3767b248 | #26658 | settings | fix(web): scheduled task editor shows the destination thread | port |
| 2b15ba077d | #27891 | settings | fix(web): model settings show "No reasoning" instead of labeling every model | ported (settings-2): model rows label Fast mode and No reasoning only (ProvidersLogic.capabilities, ProviderOptionDescriptor.isReasoningControl) |
| 1d4c5e023f | #24890 | settings | fix(web): show the correct Tailscale URL when switching to port 443 | port |
| bfb44fbe6c | #24788 | settings | feat(web): copy the app version from General settings | port |
| 7671644754 | #26798 | settings | fix(web): restore No project name and icon from settings | port |
| 35041c27d7 | #24148 | settings | fix(copy): clarify thread and source control settings | port |
| c8e78cbd84 | #24149 | settings | fix(copy): clarify unavailable tasks and duplicate requests | port |
| f17126c261 | #27268 | settings | fix(web): sidebar metadata uses the theme's colors in dark mode | port |
| 4e6b7d8447 | #27936 | settings | fix(web): explain when a theme hides environment artwork | port |
| bc799c4ba5 | #23162 | settings | fix(web): give non-Latin theme names distinct stable ids | port |
| d3f6ace496 | #23183 | settings | fix(web): respect provider permissions in bulk updates | port |
| ef6e05e356 | #25375 | settings | fix(themes): accept VS Code JSONC imports | port |
| d64888fbc4 | #27151 | settings | fix(web): Escape while recording a shortcut no longer closes Settings | port |
| cae3ced9fb | #27376 | settings | fix(web): find the fallback model in Settings search | port |
| fcb1d0b1db | #24134 | settings | fix(web): honor editableFocus in shortcut conditions | port |
| aa056f7d0f | #24719 | settings | fix(web): the welcome wizard keeps the project selection when you go back a stage | n/a (settings-3): the Welcome page replaced the wizard's stages |
| 220bc7cc50 | #27540 | settings | fix(web): Settings search finds rows by their titles | port |
| c894d797cf | #27759 | settings | fix(providers): Antigravity API-key setup says Connect | port |
| 435cda96a3 | #23136 | settings | fix(web): keep theme color alpha when a hex value is typed | port |
| 2a9335680e | #23168 | settings | fix(web): keep saved sensitive variables from losing their value | port |
| 52b65aabce | #24655 | settings | fix(web): installing two providers at once starts both | port |
| b8badda42e | #24673 | settings | fix(web): interval settings save when editing ends, not per keystroke | port |
| 4c3808a109 | #28300 | settings | fix(web): Diagnostics memory no longer reads "1024.0 MB" | ported (settings-3): DiagnosticsFormat.bytes picks the unit after rounding (lib/formatBytes.ts) |
| edc37c96c8 | #29382 | settings | fix(web): center authorized client settings rows | port |
| a497f7b9a3 | #29480 | settings | fix(web): confirm before removing a provider instance's saved settings | ported (settings-4928): Reset and Delete on a provider instance ask first, with the turned-off note for default-off drivers |
| bff68fb6b6 | #29554 | settings | fix(shared): saving one source control token no longer drops the other hosts' tokens | port |
| 2e39f1d7de | #31826 | settings | fix(web): settings descriptions use the full row and stay two lines | port |
| 7f7bf263a8 | #32409 | settings | fix(web): recover ACP settings when projects change | port |
| 8395f20124 | #29851 | settings | fix(web): editing a scheduled task shows its saved time when the hour has one digit | port |
| 8913a4a254 | #30115 | settings | fix(web): keep typed unpublished variable rows across settings re-deliveries | port |
| e85e0094dd | #33538 | settings | fix(web): checking for updates finds provider updates on every machine | already (settings-3): UpdateEverything.check refreshes providers with refreshModels on every connected machine; the providers:manage filter and the failure toast are not ported |
| 25da7ebca6 | #33730 | settings | fix(web): reclaim notice says the machine will be offline | ported (settings-3): Reclaim says the machine will be offline for about N min |
| 7389423507 | #32576 | settings | fix(web): screen readers hear the add-project submit shortcut | port |
| f7b81e1d11 | #33395 | settings | fix(web): settings search shortcuts follow the physical key on non-US layouts | port |
| 0815d98cd7 | #34178 | settings | fix(web): make Q&A option outlines visible across themes | port |
| 43821388a9 | #18187 | settings | fix(web): focus the primary action when confirmation dialogs open | port |
| 0e1f01ec85 | #14493 | settings | fix(web): keep grouped project icons consistent in settings | port |
| 477845733d | #27484 | settings | fix(web): track switch dialog no longer offers a switch that moves nothing | left (settings-3): with #26288, nothingToMove in updateTrackSwitch.logic.ts |
| 940b7a4160 | #30841 | settings | fix(web): screen readers can browse and Tab through the settings sections again | port |
| cff8bfcef0 | #23479 | settings | fix(web): keep model favorites usable after disabling a provider | port |
| 338e73859a | #23568 | settings | fix(web): thread shortcuts work with the narrow sidebar closed | port |
| 661a3e2a47 | #34802 | settings | fix(web): Backspace right after a list shortcut keeps the typed marker | port |
| dcad1942a9 | #34858 | settings | fix(client-runtime): provider toggles no longer wait for another provider's update | port |
| 2b7e975a97 | #35008 | settings | fix(clients): say "Starting Claude" until the provider actually starts | port |
| 12d4c62214 | #35101 | settings | fix(web): every settings nav group has a name for screen readers | port |
| b2e86d7902 | #35100 | settings | fix(web): an invalid provider setting is refused at its field instead of taking the provider offline | ported (settings-2): a refused value stays in the field marked invalid with "Enter a valid value. It was not saved." (ProvidersSettingsView.swift `ValidatedFieldControl`, `Field.pattern`) |
| 32f3d8b160 | #35116 | settings | fix(client-runtime): Diagnostics Resource History keeps updating while open | port |
| a30cb3283a | #35161 | settings | fix(web): Esc in the keybindings search clears it without closing Settings | port |
| 1d218d1525 | #34697 | settings | feat(web): screen reader window title leads with the thread's status and name | left (panels-2): needs the `screenReaderWindowTitle` client setting and its Settings switch (Features/Settings), then status first in the window title (branding.logic.ts, Sidebar.logic.ts resolveWindowTitleThreadStatus) |
| 4f555c746c | #28584 | settings | fix(web): choosing a project icon again re-reads it from disk | port |
| 817b92f13a | #24110 | settings | fix(pi): stop offering extension-only models for text generation | port |
| 141de5e9f4 | #25513 | settings | fix(web): a dismissed provider banner stays dismissed when you switch threads | port |
| 56d227836b | #25244 | settings | fix(projects): preserve grouped renames to repository names | port |
| 254e985e47 | #35715 | settings | fix(web): find scheduled tasks in Settings search | port |
| 8cb55fa5a4 | #32537 | settings | fix(web): provider rows select from anywhere in the row | port |
| 6bb9b7b323 | #36303 | settings | fix(web): auto-settle days save when the edit is finished, not on every keystroke | port |
| 0517d15c41 | #36392 | settings | fix(web): provider sign-in links only open web addresses | port |
| ab9e6a2792 | #36437 | settings | fix(web): closing Settings no longer leaves it as a back/forward stop | port |
| 62ba72fa15 | #36477 | settings | fix(web): onboarding rechecks an agent when its install command finishes | ported (settings-3): the Welcome install terminal refreshes the agent when its command exits (WelcomeInstallTerminalView.onCommandFinished) |
| a81ec88f58 | #24641 | settings | fix(clients): allow portable provider handoffs after detach | port |
| fe873f82c1 | #23578 | settings | fix(web): confirm before deleting scheduled tasks | ported (settings-4928): Delete asks first |
| b2259d3c6c | #23590 | settings | fix(web): show working state while provider sessions start | port |
| 000d82dc67 | #25130 | settings | fix(web): Esc closes the theme editor, not Settings | port |
| b4c1bd106d | #35612 | settings | fix(web): re-picking the current model in Settings keeps its traits | port |
| 913d7fc45e | #28319 | settings | fix(web): PageUp and PageDown shortcut labels no longer read Pageup and Pagedown | ported (settings-3): KeybindingShortcut.keyLabel says PageUp and PageDown |
| e26e21c06b | #36628 | settings | fix(web,mobile): bound scheduled tasks no longer offer a model their runs ignore | port |
| 616067de84 | #36755 | settings | fix(web): pressing Enter in the Add CLIProxyAPI hub dialog adds the hub | port |
| 3b816cf6c7 | #36753 | settings | fix(web): ChatGPT sign-in error no longer points to a missing redirect URL field | port |
| 5fe2f7e456 | #29377 | settings | fix(web): diagnostics no longer shows near-second spans as "1000 ms" | ported (settings-3): DiagnosticsFormat.duration rounds before choosing ms or s |
| b5df3c1bef | #36789 | settings | fix(web): a scheduled task with a cleared run time no longer saves as 09:00 | port |
| 0487654fc8 | #29395 | settings | fix(web): diagnostics CPU time no longer reads "60s" or "60m" | ported (settings-3): DiagnosticsFormat.cpuTime picks the unit after rounding |
| ee4ef06469 | #28945 | settings | fix(web): use optimistic updates for settings across environments | port |
| 81f23426d4 | #36856 | settings | fix(web): Settings > Projects list follows the selected environment | port |
| 756545a917 | #36906 | settings | fix(web): successive custom model saves keep earlier edits | port |
| 01c8e59f14 | #31318 | settings | fix(web): preserve published theme IDs during alias lookup | port |
| 4dec8cf641 | #34081 | settings | fix(web): honor right panel state in custom shortcuts | port |
| da95a04763 | #35189 | settings | fix(web): right-panel shortcuts work on a new, unsent thread | port |
| 0fbe8a2e44 | #29503 | settings | fix(web): settings section headers no longer overlap their actions on narrow screens | port |
| 58f609f7cc | #30330 | settings | fix(web): theme import no longer says a file just under 1 MB is "1024 KB" | n/a (settings-3): CandyWrapper's theme import has no size message; DiagnosticsFormat.bytes follows formatBytes for any later one |
| b8bffc8b35 | #29749 | settings | fix(web): resource monitor no longer claims to sample every 0 ms | ported (settings-3): DiagnosticsFormat.samplingStatus says Sampling on demand for 0 |
| 63b5645678 | #32859 | settings | fix(web): Esc in Clerk's account modal no longer closes Settings | port |
| 6d3f6423a3 | #37198 | settings | fix(web): Enter sends when a panel-conditioned shortcut is inactive | port |
| 57ec00ddd6 | #37509 | settings | fix(web): source control settings notice a CLI login made outside the app | port |
| 83e3c4f60d | #37493 | settings | fix(web): published themes keep their CSS when a saved theme shares the id | left (settings-3): CandyWrapper has no CSS engine; needs a decision on theme CSS (themeCss.ts strips every value themeCssValueFetches flags; a native port could read only :root custom properties for known tokens after that check) |
| d6a28f4faa | #37818 | settings | fix(client): guard saved environment routes during SSH onboarding | port |
| 4021638273 | #31527 | settings | fix(web): thread hover cards show the provider icon in its brand color | port |
| cd9c39fe3c | #37982 | settings | fix(web): imported theme files keep their top-level canvas and accent | port |
| d051d9822f | #38021 | settings | fix(web): leaving Appearance cancels a pending theme install | port |
| 81049d2b92 | #38134 | settings | fix(web): importing light and dark theme files together keeps their custom CSS | port |
| 077b206b33 | #38139 | settings | fix(web): same-named themes renamed on batch import keep their CSS | port |
| b48a20bc85 | #38944 | settings | fix(web): settings search icons line up with their titles | port |
| 26b872b46a | #38996 | settings | fix(web): hiding a revealed email no longer flashes its placeholder | port |

## Small fixes, sidebar (74)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 221610f0ca | #26736 | sidebar | fix(web): keep settled drop hint inside the sidebar viewport | skip: dnd-kit scroll of the projected drop box; CW drags with its own session |
| 69310dbd61 | #22412 | sidebar | fix(web): the ~ breadcrumb opens the home folder | skip: files breadcrumb, outside the sidebar |
| d5536f6052 | #24209 | sidebar | fix(web): name the sidebar logo link T3 Code home | skip: web link name; CW's brand is not a link |
| c84acfa205 | #24109 | sidebar | fix(web): keep later navigation when thread archival completes | already in CandyWrapper: App/Sources/SidebarCommands.swift navigates before the archive request awaits |
| f048a9b617 | #25444 | sidebar | fix(web): archiving or deleting a thread expires its earlier Undos | ported 9a0153d1 |
| 32ce9db80b | #26803 | sidebar | fix(web): remote machine icon no longer forces a third sidebar line | ported 9f448337 |
| 8df96fb3ec | #26477 | sidebar | fix(web): add tooltips to boring sidebar actions | ported 9a0153d1 for the folder header; the settle check already had its tooltip (RowActionButton) |
| f204389a66 | #22027 | sidebar | fix(web): match sidebar footer bottom padding to its horizontal inset | ported 0166b1ef |
| e1e60080b9 | #22311 | sidebar | fix(web): collapsing a changed-files folder no longer leaves a one-frame gap | skip: changed-files tree, outside the sidebar |
| 033a753e34 | #26195 | sidebar | fix(web): threads on an unreachable environment no longer hide in the Working shelf | no net change: reverted by #31269 |
| 2a4d1288c5 | #23360 | sidebar | fix(web): line up the Date and Time fields in custom snooze | ported 9f448337 |
| 1dacdb9460 | #26112 | sidebar | fix(web): sidebar jump hints are readable and sit in the status slot | skip: CW has no modifier-hold jump hints in the default themes, only Redesign's hover badge |
| e0fa102aa3 | #27327 | sidebar | fix(web): changing the sidebar project filter starts the list at the top | ported 9f448337 |
| c77f755090 | #28179 | sidebar | fix(web): sidebar drops a deleted project's filter with the local environment disabled | skip: web desktop-bridge check |
| da216062c9 | #28605 | sidebar | fix(web): sidebar project filter no longer refocuses after a pick | already in CandyWrapper: a pointer close leaves no focus ring on the filter trigger |
| e2ad07abad | #27231 | sidebar | fix(web): settled shelf no longer crashes with several projects filtered | already in CandyWrapper: demandOlderSettled takes a Set, so project order never changes its key |
| abcff3e49a | #27695 | sidebar | fix(web): the undo notice no longer pushes the update button out of the sidebar | ported 9a0153d1 with the footer row layout |
| 52715df387 | #28428 | sidebar | fix(web): folder rows no longer jump at larger interface font sizes | skip: CSS content-visibility hint, web only |
| 52d755f91c | #28460 | sidebar | fix(clients): pasting a path copied from Finder or Explorer adds that folder | skip: path paste in Add project and the palette, outside the sidebar |
| e925dd6819 | #27785 | sidebar | fix(web): allow folder references on saved local desktop servers | skip: composer folder references, outside the sidebar |
| 5b9731cedc | #26690 | sidebar | fix(web): screen readers can browse and Tab through the threads sidebar again without going into focus mode | skip: web ARIA focus mode |
| e1e520c93c | #29704 | sidebar | fix(web): show the project pin before the remote badge | ported (side-chats): SidebarProjectScopeView rows, sidebar-project-filter spec |
| 115739c1e0 |  | sidebar | fix(web): keep the project filter menu aligned with its trigger | ported (composer-5): the project filter popup anchors to its filter button at min(288, available), aligned to its start and shifted into the window (SidebarView `toggleScopePopup`) |
| 7239986680 | #29643 | sidebar | fix(web): deleting the open thread no longer opens a snoozed or settled thread | ported 9a0153d1 |
| dd8c122c5d | #30063 | sidebar | fix(client): keep snoozed failures hidden without completion times | ported 9a0153d1 |
| 20e92ffe02 | #29639 | sidebar | fix(web): sidebar project filter rows line up and stay still on hover | ported (side-chats): the pin column and stand-ins, sidebar-project-filter spec |
| 37481f044e | #30346 | sidebar | fix(web): dragging a sidebar thread no longer scrolls the list out from under the pointer | skip: dnd-kit auto-scroll, web only |
| fb9f1c6f33 | #31642 | sidebar | fix(web): keep the folder path caret in place while editing | skip: palette folder path field, outside the sidebar |
| bfb388415e | #30596 | sidebar | fix(ui): snooze menu times match the menu's typography | ported 9f448337 (MenuItem.detail) |
| 10f88f34ed | #30706 | sidebar | fix(web): restore folder breadcrumb trails when reopening tabs | skip: reopened tab breadcrumbs, outside the sidebar |
| 86d8838e91 | #27691 | sidebar | fix(web): dragging a sidebar thread no longer scrolls the list to the bottom | skip: dnd-kit auto-scroll, web only |
| c8267db9ac | #31924 | sidebar | fix(web): tagging a thread by drag no longer scrolls the sidebar | skip: dnd-kit auto-scroll, web only |
| f8c7c7593f | #24202 | sidebar | fix(web): the main sidebar stays collapsed after relaunch | skip: window layout persistence lives in App/Sources, outside this task |
| e6d42567ba | #33109 | sidebar | fix(web): cmd+shift+o picks the current project before pinned ones | skip: palette project order, outside the sidebar |
| 6f8c7433d0 |  | sidebar | fix(web): new threads use the last used project | skip: new-thread project choice in App and the palette, outside the sidebar |
| 580503ed30 | #33759 | sidebar | fix(web): custom snooze footer stays inside the dialog | ported 9f448337 |
| 30c11a3c74 | #32507 | sidebar | fix(web): the thread menu works for an older settled thread the sidebar hasn't loaded | skip: thread route menu, outside the sidebar |
| 8030067470 | #24945 | sidebar | fix(web): snooze times read naturally in context menus | already in CandyWrapper: native menus read "Label (time)" as ElectronMenu.ts does |
| 2904fea7d5 | #29445 | sidebar | fix(web): Mod+B toggles bold at a collapsed cursor when the sidebar toggle is remapped | skip: composer bold shortcut, outside the sidebar |
| bb646d2cad | #34759 | sidebar | fix(shared): links to bracketed filenames keep their folder labels | skip: Markdown links, outside the sidebar |
| 1e848876ee | #34929 | sidebar | fix(web): a sidebar click no longer gets lost when the release reports no buttons | skip: web pointer release quirk |
| fc2b5de20c | #35426 | sidebar | fix(web): a project filter that hides every active thread says so and offers Show all projects | ported 9a0153d1 |
| 8fc1dade71 | #35522 | sidebar | fix(web): keep settled pagination focused while loading | already in CandyWrapper: the Show more row keeps list focus while it loads |
| a7779fc558 | #35499 | sidebar | fix(web): a focused folder New thread button no longer draws over the hidden-thread count | already in CandyWrapper: SidebarRowViews.swift shows the folder New thread button and the count never together |
| b1c1e07ded | #23517 | sidebar | fix(web): a click no longer lands on the sidebar row that just slid under it | ported (sidebar-2): SidebarShiftGuard drops presses for 500ms on rows that moved half a row without the user's input |
| db470a3ebd | #35659 | sidebar | fix(web): legacy collapsed project folders stay collapsed after a save | skip: web localStorage migration |
| 2d80cb6bc7 | #36420 | sidebar | fix(clients): live working timers count on the host's clock | ported (sidebar-2): ServerClock records the first config snapshot's serverTime; sidebar timers count on it. The timeline's work group timer (Features/Thread) still reads this Mac's clock |
| dea07a1b12 | #36467 | sidebar | fix(web): rewind no longer offers file restore in project-folder threads | skip: rewind file restore, outside the sidebar |
| 1f55acf13b | #36543 | sidebar | fix(client-runtime): refresh settled counts when threads move project | already in CandyWrapper: ShellReducer.swift invalidates counts on any update of an older settled thread |
| 306914f016 | #35614 | sidebar | fix(client-runtime): grouped projects no longer take one folder's name as their label | ported (sidebar-2): deriveProjectGroupLabel names a whole-repository group after the repository |
| 28f1786829 | #36590 | sidebar | fix(web): recreated folders no longer show deleted files | skip: files panel, outside the sidebar |
| df8c1a1fd4 | #25269 | sidebar | fix(web): Narrator highlights the sidebar thread title where it is drawn | skip: web Narrator highlight |
| 96735d7311 | #27109 | sidebar | fix(web): picking a sidebar search result scrolls the list to that thread | already in CandyWrapper: revealRouteRow scrolls to the opened result |
| cc0a7bb9d8 | #28644 | sidebar | fix(shared): file links with parentheses in the path keep their parent folder labels | skip: Markdown links, outside the sidebar |
| 47474723cb | #28616 | sidebar | fix(web): clear failed badges when threads are opened | ported 9f448337 |
| 04572419e4 | #36785 | sidebar | fix(clients): a one-hour snooze no longer reads "2h left" | ported 9a0153d1 |
| 752bdaeb70 | #26376 | sidebar | feat(client): add-project folder search matches substrings and fuzzy subsequences | ported (panels-2): folder search ranks exact, prefix, boundary, substring and fuzzy matches, PaletteAddProjectPaths.filter |
| 9888694f80 | #36909 | sidebar | fix(client): refresh open archive when threads are archived elsewhere | skip: Settings archive list, outside the sidebar |
| 304dc13648 | #30428 | sidebar | fix(web): opening a project or deleting the open thread skips delegated tasks | ported (sidebar-2): delegatedFrom decodes; a task from a listed parent leaves lists, the delete fallback and project opening (lineage.isListed) |
| 26bf047d5e | #30597 | sidebar | fix(client-runtime): a disconnected machine's scratch folder no longer lists as a second "No project" | already in CandyWrapper: ThreadSession.swift keeps the last scratch folder while a machine is away |
| fe59fa44d0 | #31009 | sidebar | fix(web): renaming a sidebar thread no longer shifts the row or covers it with the hover card | ported 0166b1ef |
| 81df733306 | #31894 | sidebar | fix(web): opening a project from the command palette skips settled and snoozed threads | skip: palette, outside the sidebar |
| 86cdf80dbd | #33083 | sidebar | fix(web): sidebar edge uses the same resize cursor as side panels | skip: the sidebar splitter cursor lives in App/Sources |
| ab319a52dd | #37054 | sidebar | fix(web): attach command palette threads outside the sidebar | skip: palette drag, outside the sidebar |
| 1b04bab05d | #33053 | sidebar | fix(web): settle check lines up with row timestamps | ported 0166b1ef |
| 40f63b468f | #37067 | sidebar | fix(assets): align app icons and retain a folder placeholder while loading | skip: Markdown file links and server icons, outside the sidebar |
| 40dcbc5f6a | #37475 | sidebar | fix(web): a stopped run no longer shows the green Done badge in the sidebar | ported 9a0153d1 |
| 45dedf2955 | #37500 | sidebar | fix(web): an open delegated task selects its parent's sidebar row | ported (sidebar-2): SidebarModel.resolveListedAncestorThreadId picks the row |
| 1d1489d0b8 | #37727 | sidebar | fix(web): keyboard-opened sidebar menus select their first item | skip: CW opens native menus, where AppKit handles keyboard selection |
| d405bd94ac | #29520 | sidebar | fix(web): sidebar width recovers when the window widens after a narrow start | skip: sidebar width lives in App/Sources |
| 55c134a346 | #37925 | sidebar | fix(client-runtime): Tab completes a folder name when the list shows fuzzy matches | skip: Add project folder completion, outside the sidebar |
| 9b3b1c79a7 | #38155 | sidebar | fix(client): a thread search that fails says so instead of "No results" | ported 0166b1ef in the sidebar; the palette half is outside it |
| e6265a926e | #38545 | sidebar | fix(web): thread jump hints re-check when a modifier changes while the hold is already met | skip: modifier-hold jump hints, see #26112 |
| 6927cfe2ad | #38722 | sidebar | fix(web): dropped folders open on this computer's server when the desktop app's own environment is off | n/a (sidebar-2): the primary is always this computer's server here; no setting turns it off while another connection shares its home |

## Small fixes, terminal (35)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| bfee44655c | #22106 | terminal | fix(web): keep a closed split terminal's tab in view | left (panels-3): not checked on screen; TerminalDrawerView's tab strip needs a split closed while scrolled to confirm the tab stays in view |
| 947916887c | #27515 | terminal | feat(pi): import terminal Pi sessions during setup | n/a: Pi session import runs in the server's setup |
| 8f79233ccb | #24020 | terminal | fix(web): keep terminal close confirmations on their original thread | already in CandyWrapper (panels-3): the close confirmation is a modal dialog (TerminalController.confirmClose), so the thread cannot change while it is open |
| cd7791de1e | #24251 | terminal | fix(web): expired terminal context toasts say "them" for several contexts | n/a (panels-3): CandyWrapper shows no expired terminal context toast |
| f513369612 | #28189 | terminal | fix(web): terminal URLs like redis:// no longer become broken file links | ported (panels-2): the tail of a non-web URL such as redis:// or file:/// is no file link, TerminalLinks.extract |
| d7171d30a4 | #27843 | terminal | fix(shared): inverted terminal ranges emit no fake lines | n/a (panels-3): CandyWrapper shows a terminal record's text as sent and slices no lines from its range (MarkdownContextChips) |
| ee265cc539 | #29696 | terminal | fix(client-runtime): terminals fit their pane again after a reconnect | left (panels-3): refitting after a reattach snapshot needs a check of TerminalController's attach stream against a server restart |
| 77b948e3e7 | #29804 | terminal | fix(web): big terminal selections no longer break sending | n/a (panels-3): xterm.js selection size limit; SwiftTerm's selection goes to Add to chat as text |
| 7f92cb0e49 | #29736 | terminal | fix(shared): ignore unsupported command output control parameters | ported (panels-3): private parameters and colons outside SGR are ignored, CommandOutputBuffer |
| 16ca47b3d3 | #29737 | terminal | fix(shared): ignore unsupported command output erase modes | ported (panels-3): erase modes other than 0, 1 and 2 (K) and 0-3 (J) leave the text, CommandOutputBuffer |
| 059804dfda | #30526 | terminal | fix(web): validate terminal links against filesystem metadata | left (panels-3): validating path links against filesystem metadata needs a stat RPC before TerminalLinks marks a path |
| 1b14cb3d8c | #30603 | terminal | fix(web): terminal links keep route and pnpm paths in one piece | ported (panels-2): route segments like [id] and (group)/ and pnpm paths with @ stay in one link |
| a3cd0aa823 | #29164 | terminal | fix(web): deleting an archived thread also clears its draft, staged uploads and terminal state | left (panels-3): deleting an archived thread clearing its terminal state touches the thread delete path in the app, not checked |
| 9cd7a04797 | #33440 | terminal | fix(web): sending from an empty citation comment clears the composer | left (panels-2): composer, outside the terminal |
| facd190640 | #33129 | terminal | fix(web): opening the terminal with Cmd+J no longer re-renders the whole sidebar | n/a (panels-3): React re-render cost |
| 05adc163fc | #34182 | terminal | fix(web): hide empty replies when renders show the result | left (panels-2): thread timeline, outside the terminal |
| f697d4db3e | #34050 | terminal | fix(web): local server cards in the browser empty state take pointer clicks | left (panels-2): browser empty state, see the browser batch |
| 3445b0b400 | #24773 | terminal | fix(web): terminal output no longer edits a hidden question draft | n/a (panels-3): CandyWrapper's terminal output never writes into a composer draft |
| 34de974868 | #34899 | terminal | fix(web): clicking the timeline's empty padding keeps following a streaming reply | left (panels-2): thread timeline, outside the terminal |
| a2685e64d3 | #35404 | terminal | fix(web): SCP-style Git remotes no longer become terminal file links | ported (panels-2): an SCP-style Git remote's tail is no file link |
| 8a38c63706 | #26433 | terminal | fix(web): thread navigation shortcuts work from the terminal and macOS composer | already in CandyWrapper (panels-3): thread navigation shortcuts go through the app-wide Shortcuts registry, which runs with the terminal focused |
| 1acee5b8be | #36025 | terminal | fix(web): terminal OSC 8 file URIs open the file they name | ported (panels-3): an OSC 8 file:// link opens the file it names with its #L position, TerminalController.openLink through FileLinks.resolveLink |
| ed7e5010ba | #36117 | terminal | fix(web): terminal "Add to chat" now adds to a queued message being edited | left (panels-3): Add to chat into a queued message being edited is a Features/Composer change, held for the composer agent |
| 764c0475b5 | #36174 | terminal | fix(web): terminal TypeScript links preserve error locations | ported (panels-2): `file(42,7): error TS…:` links to file:42:7 |
| 1721f187c6 | #36380 | terminal | fix(web): clearing a running terminal keeps its screen and input modes | n/a (panels-3): SwiftTerm keeps its modes through a clear; T3's fix replays its own retained buffer |
| 43a71d9b1a | #29654 | terminal | fix(web): a terminal reopened while its open is pending no longer closes itself | left (panels-3): reopening a terminal while its open is pending needs a check of TerminalController's open and attach ordering |
| 382312aba8 | #29612 | terminal | fix(web): the sidebar shortcut honors terminal and preview focus conditions | already in CandyWrapper (panels-3): sidebar.toggle runs through the Shortcuts registry with its when-clauses, whatever has focus |
| e0ca4fcecb | #32047 | terminal | fix(web, mobile): a failed terminal resize is sent again | left (panels-3): resending a failed resize needs a retry in TerminalController's outbox on a failed terminal.resize |
| 2cb2fa1385 | #37071 | terminal | fix(web): terminal links open bare compiler filenames | ported (panels-2): a bare `name.ext:line:col` links |
| e101cae1b9 | #37088 | terminal | fix(terminal): show shell startup failures across attachments | left (panels-3): shell startup failures across attachments need the attach snapshot's failure state shown in TerminalSurfaceView |
| 8dba23e420 | #37103 | terminal | fix(web): large terminal pastes reach the program intact | already in CandyWrapper (panels-3): pastes go out in ordered chunks through TerminalRPC.writeChunks and the attachment outbox |
| 46f3ab39f2 | #37133 | terminal | fix(web): open terminal file links naming the server hostname | left (panels-3): file URIs naming the server's hostname need the server config hostname passed to the link resolver |
| 304cf149c8 | #37201 | terminal | fix(web): terminal file links preserve numeric filename suffixes | ported (panels-2): `$`, `+` and `@` in names keep numeric suffixes in the link |
| 48a64a8b68 | #35305 | terminal | feat(web): make terminal close confirmation optional | ported (settings-2): General > Confirmations > Terminal close confirmation, and TerminalController.confirmClose skips the dialog when it is off |
| 17c401ddc0 | #38998 | terminal | fix(web): drawer drops a background terminal closed by another client | left (panels-3): dropping a background terminal another client closed needs the drawer to follow the session list's closed state |

## Small fixes, thread (266)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| d464631407 | #26379 | thread | fix(web): image chips drop the pill and match other chips | port |
| 725573f358 | #26639 | thread | fix(web): double-click selects the whole inline code span | port |
| ecea6ca3e6 | #21878 | thread | fix(web): edit from here uses a pencil icon | port |
| 3d5baafecf | #22100 | thread | fix(web): respect reduced motion in thread loading controls | port |
| 6ca95bd92a | #23626 | thread | fix(web): Enter no longer skips an unanswered question | ported: Next and Enter stay on an unanswered question (T3Store `UserInputSession.advance`) |
| 616c426f5f | #27372 | thread | fix(shared): TypeScript files no longer show as videos | ported: `video/mp2t` and `video/vnd.dlna.mpeg-tts` attachments stay files in sent messages and their chips (thread-2, T3Store `isPlayableVideoMime`). Left: the composer's own check in ComposerAttachments (Features/Composer) |
| 8d012a688e | #27522 | thread | fix(web): a new thread's first reply shows without reloading | port |
| a0d6cc8ba9 | #21594 | thread | fix(client-runtime): goal token counts no longer read 1000k | ported: goal usage reads 1m, not 1000k, from 999,500 tokens (thread-2, ThreadRecoveryPresentation) |
| f47700849e | #22141 | thread | fix(web): show the result of the notified delegated task | port |
| 5ad7da060d | #22367 | thread | fix(web): keep markdown separators visible in dark mode | ported in eceea265 |
| 9ceb949a01 | #22875 | thread | fix(web): copied Markdown tables keep formula pipes | ported (thread-3): table Copy as Markdown keeps formula pipes (MarkdownLayout.markdown) |
| c40b32a729 | #23448 | thread | fix(web): keep ACP agent logos in multi-model selections | port |
| 3bd744fc11 | #23679 | thread | fix(web): show clipboard errors in anchored copy notifications | n/a: web clipboard API errors; NSPasteboard writes don't fail this way |
| 17580724fc | #26067 | thread | fix(web): byte sizes just under the next unit no longer read "1024 KB" | ported (thread-3): StorageCleanupReport.formatBytes picks the unit after rounding |
| 9ad6c7ef8b | #26145 | thread | fix(web,mobile): long links in secret requests wrap and can be copied | port |
| 22463861cd | #26151 | thread | fix(web): clicking a secret request card focuses its field again | port |
| 1b9437f6ab | #27078 | thread | fix(web): long pending-question headers truncate instead of overflowing | port |
| 609dd0f7dd | #27144 | thread | fix(web): plain text code blocks match the text around them | ported in eceea265 |
| 12d1e4c23c | #22339 | thread | fix(web): keep truncated Markdown task previews read-only | port |
| 469afd8b53 | #23351 | thread | fix(chat): commands that exit 0 no longer show as failed | ported (thread-3): WorkLog.checkFailure trusts the exit code over output and command text |
| da94a13e59 | #23954 | thread | fix(web): tab to equations only when they overflow | port |
| f3bbd0fd07 | #21378 | thread | fix(web): video full-screen buttons work in HTML renders | port |
| 447d71d901 | #25838 | thread | fix(web): chat stays centered while the thread details card fits beside it | port |
| 191cd7e789 | #25948 | thread | fix(web): match HTML render backgrounds to the dark chat theme | port |
| fd08b170b6 | #26871 | thread | fix(web): punctuation after a file chip stays on the chip's line | already in CandyWrapper: a chip is a run of the same attributed text, and line breaking never breaks before closing punctuation (Features/Markdown/MarkdownLayout `text`) |
| f2cd7a1e63 | #25199 | thread | fix(web): show complete tooltip labels when opening | n/a: CSS tooltip entry animation; AppKit tooltips draw whole |
| 09ac55639a | #26716 | thread | fix(web): popovers fade out in place instead of jumping after a pick | port |
| eef35b0262 | #26762 | thread | fix(clients): stop loading thread families when opening chats | port |
| 0343c83aa6 | #24833 | thread | fix(web,mobile): lineage and agent rows show which account a subagent runs on | ported: lineage rows draw the subagent's instance badge on its glyph and lift the status dot to the top corner while any instance shows one (thread-2, ThreadRelationshipIconView). Left: workflow member rows |
| 2c59bf66c7 | #24898 | thread | fix(web,mobile): subagent cards show which account each subagent runs on | ported: subagent cards draw the instance badge on the avatar's glyph and lift the dot the same way (thread-2, SubagentCardLinkView, ThreadViewModel `providerBadge`) |
| bfd37b774b | #27310 | thread | fix(web): Queued messages can be edited during Compact and send | port |
| b0aa468aa1 | #23621 | thread | fix(web): copy and save images embedded as data URLs | already in CandyWrapper: copy and save use the loader's decoded image, and MarkdownImages.decodeData reads data URLs |
| c2dc2eaaf5 | #24050 | thread | fix(web,mobile): Hebrew and Arabic read right to left in questions, citations, attachments and diff comments | port |
| b5ced43833 | #25746 | thread | fix(web): local visit migration preserves mark unread | port |
| 6525e4cb59 | #26232 | thread | fix(web): maximize button no longer jumps when the right panel closes | port |
| aa8dbbe54f | #27741 | thread | fix(web): skill labels show the skill's own name | port |
| 4ed4950b7c | #23024 | thread | fix(client): reject incomplete GitHub owner paths before lookup | port |
| 41b3b0b1b6 | #25002 | thread | fix(clients): background work Stop stays pending until the stopped tasks leave | port |
| 510aa5af40 | #26095 | thread | fix(web): Arabic paragraphs with many English terms now read right to left | port |
| b46a4edc03 | #26398 | thread | fix(web): dark-mode <picture> images load instead of showing "Image unavailable" | skip: CandyWrapper draws no raw HTML `<picture>` in replies yet; take it with raw HTML support |
| 58f8ab47a0 | #27794 | thread | fix(web): bare URL links keep trailing underscores and tildes | ported: a bare URL takes back the trailing `_` and `~` that GFM's autolink drops (thread-2, MarkdownDocument `keepingBareLinkTails`) |
| 16f35ce29b | #27841 | thread | fix(shared): truncate keeps emoji whole | n/a (thread-3): Swift String.prefix cuts at whole characters |
| 46e90bad0d | #28585 | thread | fix(web): many automations no longer hide the thread details Automations section | ported (settings-4928): automations no longer count toward the card's density fit; the list's 13.5rem scroll cap is not ported |
| 5884d43481 | #23588 | thread | fix(web): sort pull request lists and timelines by time | port |
| d05e4f8e8f | #28285 | thread | fix(web): streamed replies render a list's code block as the finished reply does | ported (thread-3): MarkdownDocument.stableCut stops at a line left of an open list fence |
| 05c0ed7da6 | #28969 | thread | fix(web): clarify the waiting label for background work | port |
| ec3ebdbb67 | #29166 | thread | fix(web): preserve scroll position when expanding work details | port |
| 701e13cebb | #29329 | thread | fix(web): hide image action tooltip in expanded viewer | port |
| b7ab02e0f6 | #29755 | thread | fix(web): copied code blocks keep their blank lines in lists, quotes and longer fences | n/a (thread-3): T3 serializes a DOM selection back to Markdown; CandyWrapper copies code blocks from their source |
| e53672d8fc | #28684 | thread | fix(web): long server lists in thread details now page 4 at a time | ported (settings-4928): Servers shows four, then Show N more pages four at a time, and the extra rows stay out of the density fit |
| ac10bb4aba | #29038 | thread | fix(web): mouse wheel over the thread minimap glides instead of jumping | port |
| 65efae1adb | #28637 | thread | fix(shared): relative file links with routing punctuation open as files | ported in 93df13b9 |
| 31564dece8 | #29759 | thread | fix(shared): find in thread matches a word typed with a curly apostrophe | ported (thread-3): ThreadFindText.fold folds curly apostrophes |
| 480eb8d219 | #29814 | thread | fix(client): mark unread sticks on a thread reopened within ten minutes | port |
| a185dd9248 | #30527 | thread | fix(web): give dialog titles a readable line height | port |
| d51bc58f5e | #30389 | thread | fix(tools): show images from MCP and OpenCode outputs | left (thread-3): TurnItemDetail formats structuredContent and image markers for MCP outputs (client-runtime work-log/itemDetail.ts at 4928); about 40 lines plus tests |
| 567a105705 | #30606 | thread | fix(client-runtime): expire missing file metadata per thread | port |
| c15e49a77c | #26435 | thread | fix: keep older pending questions answerable | ported (thread-3): history pages reveal older approval and question cards (ThreadReduction.mergeOlderHistory) |
| 9bfecb8f1e | #29000 | thread | fix(web): deleted forks no longer remain in Lineage | port |
| c0cb75e815 | #31653 | thread | fix(web): screen readers no longer read out a secret typed into the request card | port |
| 66a2f35711 | #30367 | thread | fix(shared): long assistant quote chips no longer end in a broken character | n/a (thread-3): Swift String.prefix cuts at whole characters (MarkdownContextChips, ThreadAssistantCitation) |
| 6f51361a27 | #30391 | thread | fix(client-runtime): subagent previews no longer end in a broken character | n/a (thread-3): Swift String.prefix cuts at whole characters (SubagentCardRowView.hoverPreview) |
| 53f1d09470 | #30528 | thread | fix(web): refresh resource timeline while diagnostics is open | port |
| 47a89f2ee7 | #30762 | thread | fix(shared): shortened agent paths like /tmp/... no longer become broken file chips | ported in 93df13b9 |
| fe199e35ca | #30390 | thread | fix(client-runtime): untitled subagent titles no longer end in a broken character | n/a (thread-3): Swift String.prefix cuts at whole characters (ThreadRelationships.swift:72) |
| ef81fd15ca | #31888 | thread | fix(web): keep task updates static in the timeline | port |
| 6dcaf6cbe7 | #29285 | thread | fix(web): remote subagents no longer split from the lineage list | port |
| 8bf1b64cae | #32141 | thread | fix(web): the citation comment box opens at the quote instead of sliding in from the corner | port |
| 07508ffd2f | #31794 | thread | fix(web): popovers over the desktop header respond to the pointer | n/a: Electron's title bar drag region; AppKit hit-tests popups above the window chrome |
| 08a3909406 | #31825 | thread | fix: show latest reply age in active thread rows | ported 9a0153d1 |
| 48bb784e3d | #32403 | thread | fix(shared): inline code like `allocator.cc:217` becomes a file chip | ported in 93df13b9 |
| 57ded10b74 | #25694 | thread | fix(web): restore bold weight in rendered Markdown | ported in eceea265 |
| 28eff11d81 | #27582 | thread | fix(web): lineage phase headers truncate instead of overflowing the details card | port |
| 6417151c09 | #32926 | thread | fix(web): fill combobox search fields | port |
| 9c0baf481e | #24084 | thread | fix(web): keep the wide table scrollbar visible when it overflows | port |
| 78756043c2 | #27993 | thread | fix(web): file chip tooltips show the whole path | already in CandyWrapper: Features/Markdown/MarkdownView.swift FileChipHitView shows the whole targetPath |
| 69dd6956d5 | #33192 | thread | fix(web): return focus to composer after timeline prompts | port |
| 2b1db482d0 | #28667 | thread | fix(web): open citation comments with the caret at the end | port |
| 739aba73b7 | #29025 | thread | fix(web,mobile): per-thread auto-settle menu says what it does | port |
| ceed427d79 | #29601 | thread | fix(web): removing a queued message's attachment counts as an edit when its run starts | port |
| 6e4711d376 | #33525 | thread | fix(web): clicked workspace areas no longer show the focus ring after a stray key | port |
| 45e0143cf1 | #33598 | thread | fix(web): thread title menu opens without a half-second wait on desktop | n/a: the desktop shell's menu delay; CandyWrapper's title menu opens on click |
| ad989057ba | #32643 | thread | fix(web): dropdown items over the desktop title bar respond to clicks | n/a: Electron's title bar drag region |
| 046efd791e | #26630 | thread | fix(web): scrolling pans expanded images and Mermaid diagrams | left (thread-3): ExpandedImagePreviewView is Features/Composer, another agent's area; plain scroll pans, pinch or Ctrl+scroll zooms |
| 16a6c1c41f | #33647 | thread | fix(web): show details for background commands | port |
| 934c7f8d8e | #33724 | thread | fix(web): center short PR titles in thread details | port |
| e4d86abca9 | #33181 | thread | fix(web): remote Lineage rows keep their title when the environment name is long | port |
| ac5e48c612 | #32719 | thread | fix(web): notify when a new request replaces the pending one in a run | port |
| 57d5e98272 | #33038 | thread | fix(web): minimap next turn is disabled at the bottom of a thread | port |
| e509db3a2f | #32605 | thread | fix(web): Tab reaches the add-project and new-project submit buttons | port |
| 20723d6d9b | #32520 | thread | fix: Claude monitor wakes no longer fire a completion alert per line | port |
| 08af12da49 | #33994 | thread | fix(shared): show zero seconds in minute durations | already in CandyWrapper: durations read `1m 0s` (screens-port, T3Store ThreadRelationships `formatDuration`) |
| 3051b32502 | #33943 | thread | fix: chat file links open the file agents cite | left (thread-3): needs the workspace basename lookup CandyWrapper lacks (ThreadSession onRevealFile ponytail); #35036 builds on it |
| 283fa1f1cd | #34011 | thread | fix(clients): scroll truncated command output notice with logs | port |
| d256170b34 | #34006 | thread | fix: file links with line ranges open at their first line | ported in 93df13b9: a range opens at its first line; the label check ignores the end line |
| d6d1763d41 | #33820 | thread | fix(web): sent messages keep the numbers written on list items | ported: sent messages keep each ordered item's written number and draw every level in digits; the gutter widens by the numbers shown (thread-2, MarkdownDocument `keepWrittenNumbers`). Left: copying a list keeps CommonMark's numbers (markdown-clipboard.ts) |
| 43915a4064 | #34095 | thread | fix(web): question panel header text sits centered in its row | port |
| ccc7b2d96f | #33352 | thread | fix(web): MCP App cards no longer flash white in dark mode while the app loads | port |
| 32fdad5f49 | #32151 | thread | fix(web): timeline minimap preview no longer steals hover or jumps around | port |
| 5b11efe5df | #30473 | thread | fix(clients): images the agent opens stay visible in the chat | ported in 2eb8794e |
| 11611419f3 | #33396 | thread | fix(web): trackpad flicks over the right panel tabs no longer navigate back | n/a: browser back-swipe navigation, which AppKit views don't have |
| 1c17285e58 | #28084 | thread | fix(shared): cite assistant messages with IDs over 512 characters | port |
| d835e430db | #22874 | thread | fix(web): question answers submit while normal sends are blocked | port |
| 691b9709b0 | #26408 | thread | fix(web): Ctrl + "+" zooms on keyboard layouts with a dedicated plus key | n/a: browser zoom shortcuts on keyboard layouts; CandyWrapper has no page zoom |
| b3f5d52701 | #24138 | thread | fix(composer): steer instead of queueing during automatic compaction | port |
| f3da8ff63b | #30575 | thread | feat(gitlab): resolve overview threads from Summary and Timeline | ported (panels-2): `overviewThreads` decode after the line threads and head "Overview" without a file glyph in the Timeline; Summary cards leave out the location |
| afa617b465 | #15255 | thread | fix(web): branch picker no longer interrupts a running turn | port |
| 3ed5fb29bd | #26311 | thread | fix(shared): Claude plugin skills no longer show their name twice | port |
| e6afd2a24b | #22148 | thread | fix(web): render citation chips in the collapsed composer | port |
| 6f2ce81958 | #24433 | thread | fix(web): copying commands with prose no longer adds code fences | port |
| 1a1a57376c | #22226 | thread | fix(web): start clone when destination is picked in file manager | port |
| 1843c93e39 | #30768 | thread | fix(chat): keep scratch file links usable | port |
| 3aea6553d3 | #18442 | thread | fix(clients): show the right app name and thread context | port |
| a9f2d7d5f4 | #34306 | thread | fix(web): "Show full message" only appears when it at least doubles the message | left (thread-3): the fold would need the body's laid-out height (twice 176 pt) instead of shouldCollapseUserMessage in TimelineMessageRows.swift, which the on-screen agent is editing; needs a fidelity check of user messages |
| b20bbc595d | #34581 | thread | fix: deliver steering after worktree setup | ported in 818d32f4: promote-to-steer on a preparing run. CW already treated preparing and starting runs as running. CW blocks sends during setup, so the planComposerTurn change is n/a |
| b859968cab | #25866 | thread | fix(web): a pending approval is announced once, not once per queued message | port |
| bba1c13d87 | #24313 | thread | fix(web): opening a thread dismisses its notification toasts | port |
| a6c26d3e77 | #27909 | thread | fix(web): the composer shows arrow ligatures like sent messages | port |
| 2a8ec9c8e1 | #23573 | thread | fix(web): single-digit numbered lists no longer clip in wide fonts | port |
| 9b98bd07ba | #23615 | thread | fix(shared): new chats use the global default when the project default model is hidden | port |
| 25d2239f9b | #25901 | thread | fix(web): screen readers hear when a thread is pinned or an action is undone | port |
| 4d52d321cb | #33772 | thread | fix(client-runtime): MCP App requests with undefined values reach the server | port |
| 94f7984d2c | #23617 | thread | fix(web): preserve typed question answers when Stop cancels a turn | ported: answers typed into a question that closed cancelled or expired move to the end of the thread's prompt (UserInputAnswers `returningUnsent`, ComposerController `leaveQuestion`); thread chips they reference are not carried |
| c0b67b7631 | #34649 | thread | fix(web): wrap interruption footers as one sentence | port |
| 7271ea06a2 | #30889 | thread | fix(web): editing a queued message keeps its thread mention chips | port |
| cc624432ac | #27781 | thread | fix(web): formatted link labels wrap inside table cells | port |
| b18fefde72 | #25986 | thread | fix(web): switching a cold Claude thread to Codex no longer compacts first | port |
| a24f7a1150 | #34527 | thread | fix(web): code blocks always show their own highlighted source | n/a (thread-3): CandyWrapper highlights each block from its own source; no hash-keyed cache |
| 1c65ad032e | #30738 | thread | fix(web): Cmd+A in the rendered Markdown preview selects only the file | port |
| 1c3d5f7e82 | #34657 | thread | fix(web): a link to a thread on a linked machine no longer opens a blank pane | port |
| a6d676fd9a | #24336 | thread | fix(web): keep background tasks visible during follow-up turns | port |
| 32882540fb | #34685 | thread | fix(web): interruption footer label sits on the reason's baseline | port |
| dbfbe3993f | #34806 | thread | fix(web): questions without options no longer mention a selected option | port |
| 101e5f99a2 | #34855 | thread | fix(web): review comments in question answers reach the agent with their text | port |
| 204b140073 | #34846 | thread | fix(web): context row under the composer hides chat text scrolling behind it | port |
| 415e1cabe6 | #34883 | thread | fix(web): html render images open with the rest of their page in the viewer | ported in d1f3d2fc |
| d8b0a05a74 | #34784 | thread | fix(clients): Claude question option previews are shown under their option | ported: the option `preview` decodes (T3Store UserInputQuestion.Option) and shows under its option, outside the button, at `ps-8 pe-2 pb-1.5`, 12/16 in foreground/70 (QuestionPanelView `previews`). Plain text with its line breaks; T3 renders it as ChatMarkdown, which needs a 12px MarkdownView composer-5: Markdown previews still left, a 12px MarkdownView needs a body size through MarkdownLayout (13 font-size sites in Features/Markdown, another agent's area). |
| efd683ccc3 | #35102 | thread | fix(web): a failed send leaves the timeline when a new draft was typed | port |
| 3d6ece2b29 | #35036 | thread | fix(web): file links the agent cited from another project open that project's file | left (thread-3): needs #33943's basename lookup first, then a search of the other project roots (client-runtime workspaceBasenameLookup.ts at 4928) |
| ced85c64ff | #35076 | thread | fix(client): a message the host never answers fails after 60 seconds instead of spinning forever | port |
| 83ee96f485 | #35074 | thread | fix(web): chat text selection stays continuous while scrolling | port |
| d2b8f291d6 | #35045 | thread | fix(web): icon-only chat header controls show their name on hover | port |
| 5574cca053 | #35043 | thread | fix(web): panel resize handle no longer covers the chat scrollbar | port |
| 3a815e9749 | #35031 | thread | fix(client-runtime): relative Markdown images in a remote thread no longer show the desktop's file | n/a (thread-3): CandyWrapper never retries a remote thread's media on this Mac's server, so a relative path cannot show the desktop's file |
| 4d641633b2 | #35267 | thread | fix(web): bare URLs end at Chinese and Japanese punctuation | left (thread-3): CandyWrapper's parser leaves a URL followed by Chinese or Japanese punctuation unlinked altogether (`打开 http://localhost:18780，然后刷新` has no link), so the port needs autolink detection for that case before it can end the link at the mark |
| 13645b1904 | #35549 | thread | fix(web): align timeline activity timestamps | port |
| 932cbd4e44 | #31115 | thread | fix(web): the Fix action on a thread details PR row stays inside the card | port |
| c0df40aa54 | #33405 | thread | fix(web): queued message preview keeps inline image labels in place | port |
| 9c7618ba1c | #35603 | thread | fix(web): gitignore fences in the rich-text composer highlight as ini, as chat does | port |
| 451e3756a5 | #33953 | thread | fix(web): keep later navigation when thread deletion completes | port |
| b63d3c5923 | #26888 | thread | fix(web): sent messages honor their theme foreground | port |
| dfded9d759 | #27436 | thread | fix(web): keep the child thread open when its remote parent was deleted | port |
| 9ac4535b06 | #35634 | thread | fix(shared): token counts just below a unit boundary use the next unit | ported: token counts pick their unit after rounding, so 999,999 reads 1M (thread-2, T3Store `formatTokens`) |
| c6b18c4741 | #33353 | thread | fix(web,mobile): keep line breaks in pending question text | port |
| c4e74fe767 | #29511 | thread | Typeset equations that fail only because of an unescaped percent | ported (thread-3): MathLayout retries with escapeLiteralPercents |
| 9ccc0f8a60 | #33558 | thread | fix(editors): JetBrains IDEs open file links in the thread's project | port |
| cfad310913 | #35680 | thread | fix(client-runtime): long MCP app download names no longer split an emoji | n/a (thread-3): Swift String.prefix cuts at whole characters (ThreadMcpAppDownload.swift:33) |
| 4cfcfaf2fd | #35574 | thread | fix(web): a question answer restored with undo is no longer sent twice | port |
| c1b42c17dc | #33873 | thread | fix(client-runtime): last user message sort ignores agent-posted messages | port |
| f8372d1baf | #35681 | thread | fix(web): long screen-reader announcements keep emoji whole at the cutoff | port |
| 9b0387d6cd | #32334 | thread | fix(web): triple-click selects the whole line around links and file chips | n/a (thread-3): browser triple-click box rules; CandyWrapper draws its own selection |
| c99201cc15 | #33036 | thread | fix(web): minimap Next turn no longer sticks on adjacent user messages | port |
| 4137412fe9 | #35739 | thread | fix(web): screen readers at Everything hear context compaction start | port |
| 05cc444a4a | #35781 | thread | fix(web): a failed commit keeps the commit message you typed | port |
| ed2a319814 | #27209 | thread | fix(web): arrow and page keys scroll the conversation again after a click or F6 | port |
| f999dc1018 | #35859 | thread | fix(web): preserve single tildes in sent user messages | port |
| 1e96606cb2 | #29409 | thread | fix(client-runtime): reopened files show host edits instead of the first read | port |
| 7556047418 | #35914 | thread | fix(web): copying an image with a spaced path keeps it an image | port |
| b62e80e0a3 | #35932 | thread | fix(web): copying an alert callout keeps its alert Markdown | port |
| fb2e5a0128 | #33042 | thread | fix(client-runtime): imported threads that never ran no longer sit in Working as Waiting | port |
| dd7918e1e2 | #33347 | thread | fix(web,mobile): MCP app calls keep their tool row and result beside the app card | port |
| 5f69cac5c9 | #36079 | thread | fix(web): turn diffs cut off at the size limit say changes are incomplete | port |
| 74573fc29b | #36090 | thread | fix(web): new project publish option tells screen readers whether it is on | port |
| f62fa296f0 | #36228 | thread | fix(web): Add to another machine can find ignored files past the first 200 | port |
| c83e78fe07 | #36285 | thread | fix(web): Shift+Return after closed inline code or bold starts a plain line | port |
| 66ec37079a | #36298 | thread | fix(shared): hosted thread URLs inside other links stay as written | port |
| 250d372e51 | #36321 | thread | fix(web): images in expanded tool rows page through the group's viewed images | ported in 2eb8794e |
| cfc71e1a99 | #36357 | thread | fix(web): preview annotations in question answers reach the agent with their text | port |
| 48cdefed5a | #32108 | thread | fix(web): size markdown media whose width and height carry a px unit | skip: CandyWrapper draws no raw HTML `<img>` in replies yet; take it with raw HTML support |
| c8db8be305 | #36334 | thread | fix(web): a run waiting on foreground subagents says so instead of Thinking | ported: the Thinking row reads Waiting on a subagent or Waiting on N subagents while the run's newest entries are its own running subagents (thread-2, TimelineRows `.thinking(label:)`). Zen keeps Thinking since it hides the cards |
| cf382b0c44 | #24637 | thread | fix(web,mobile): explain missing file access for host videos | port |
| 4c7685729f | #36497 | thread | fix(web): clicking a label in an inline HTML render no longer jumps the chat | free with the runtime: the label fix is in the bootstrap the server injects |
| a4723422e7 | #26692 | thread | fix(web): screen readers no longer say "Message" twice entering the composer | port |
| 31d9b3bcd6 | #34569 | thread | fix(web): edited HTML previews outside the workspace no longer turn white | port |
| 2c61677d59 | #36250 | thread | fix(web): overlays close on a click over the desktop header | port |
| 8656cdb3a9 | #35701 | thread | fix(web): reply labels no longer cut an emoji in half | port |
| cf60628ef9 | #25213 | thread | fix(client-runtime): cache running threads when their view closes | port |
| 33372a25a2 | #23506 | thread | fix(pi): info notifications no longer render as warnings | port |
| 947c056894 | #23666 | thread | fix(web): a context submenu near the right edge no longer covers its parent menu | port |
| 3b18dc2935 | #25445 | thread | fix(web): manual compaction counts history beyond the loaded page | port |
| 2fa77fbf55 | #24045 | thread | fix(web): horizontal table scrolling preserves timeline follow | port |
| f161a4d2b5 | #28103 | thread | fix(shared): preserve literal ampersands in citation Markdown paths | port |
| 71c2410a67 | #28929 | thread | fix(web): thread details slides in on close | left (settings-4928): PanelLayoutControls slides the details card in on close; needs a look on screen |
| 666631e94e | #36712 | thread | fix(web): copied inline code keeps meaningful edge spaces | port |
| e2f164d6bb | #28968 | thread | fix(web): let subagent lists pass scrolling to the details panel | port |
| a678948483 | #28388 | thread | fix(web): pending-question digit shortcuts ignore dialogs, menus and selects | port |
| 6cb47acfb8 | #36768 | thread | fix(web): Escape that cancels a thread rename no longer also closes the find bar | port |
| cebdf39984 | #29570 | thread | fix(web): cancelled queued-message edits release their staged uploads | port |
| c666345bb9 | #29637 | thread | fix(web): subagent previews drop image marks and full link URLs | port |
| e330593141 | #36779 | thread | fix(web): bare URLs no longer swallow Arabic commas and question marks | port |
| 60e4be49cf | #36758 | thread | fix(shared): open relative Codex citations with filename punctuation | port |
| 154c5014a7 | #29834 | thread | fix(web): long preview annotation comments are no longer dropped from the message | port |
| bf74669509 | #36830 | thread | fix(web): copied email links keep their destination | port |
| a4bf7922f5 | #33248 | thread | fix(clients): undoing a settle puts the thread back where you placed it | port |
| 2abf7be914 | #35255 | thread | fix(web): trackpad scrolling no longer stalls on gaps between right panel tabs | port |
| 3238db7a86 | #36858 | thread | fix(web): Cite is offered for text an agent sent with send_to_user | port |
| 3c77d3d64b | #36867 | thread | fix(web): copied literal Markdown sends as shown | port |
| 2137f360e6 | #34308 | thread | fix(web): open editors when saving their preference fails | port |
| 0cf9423d8b | #34402 | thread | fix(web): keep thread find working with many matches in one row | port |
| b5e4342a90 | #36876 | thread | fix(web): Arabic and Hebrew folds in chat read right to left | port |
| 093c317858 | #36915 | thread | fix(web): copying from a later list item keeps its numbers | port |
| fa647599e0 | #36922 | thread | fix(web): Arabic and Hebrew artifact template cards read right to left | port |
| b9a68e0f57 | #36929 | thread | fix(source-control): repository paths match however their names are percent-encoded | port |
| 7873016460 | #36948 | thread | fix(web): allow tooltip text to wrap naturally | port |
| 0f79b4027a | #36947 | thread | fix(web): remove redundant status info icon | port |
| d080e4eb58 | #22614 | thread | fix(web): thread details card no longer jumps mid panel animation | port |
| 5bd2d0cb82 | #30712 | thread | fix(client-runtime): derive MCP download names before URI suffixes | port |
| 3a87ca8c6a | #30806 | thread | fix(client-runtime): tool output no longer rounds integers beyond 2^53 | port |
| 6c7a87cbcb | #30387 | thread | fix(web,mobile): a late MCP app teardown no longer closes the app that replaced it | port |
| dd3d4a4e4a | #37024 | thread | fix(web): prevent stray highlights when selecting shell commands | port |
| eb8b1f5246 | #31738 | thread | fix(client): avoid worktree setup flash after editing first message | port |
| e6344bebd8 | #31338 | thread | fix(client-runtime): MCP app results with images reach the app instead of waiting forever | port |
| 25a1afe7d5 | #29711 | thread | fix(client-runtime): opening an old search result keeps messages in order | ported (thread-3): plain history pages interleave at shared rows (ThreadReduction.interleave) |
| 25c44fcc33 | #30503 | thread | fix(web): use available space for project breadcrumbs | port |
| f7a1bacd27 | #30753 | thread | fix(web): subagent status dots no longer jump between corners | port |
| 843893e58c | #30084 | thread | fix(web): the minimap keeps the current turn lit while reading a long reply | port |
| 37b71a4ffe | #37079 | thread | fix(web): remove redundant subagent action from background row | port |
| 79e47e9096 | #32402 | thread | fix(shared): inline code paths like `docker/Dockerfile` become file chips | ported in 93df13b9 |
| b35c9702f9 | #36997 | thread | fix(acp): optional text questions can be left blank | port |
| 8897a6ebe1 | #37183 | thread | fix(web): keep thread mentions when editing sent messages | port |
| 598296e850 | #37284 | thread | fix(web): copied code blocks drop the fence's trailing newline | port |
| 58b6e1c5ba | #37395 | thread | fix(web): a disabled Merge back button shows why it is disabled | port |
| 1b84e72a6d | #37507 | thread | fix(web): Cmd+Enter on an edited queued message steers it into the running turn | port |
| 56f41466f5 | #37557 | thread | fix(web): sending a new thread's first message no longer scrolls the sidebar | port |
| dfeaf7b137 | #37579 | thread | fix(web): Tab from a citation comment reaches Save, not Cancel | port |
| 1ae5590a32 | #37204 | thread | fix(web): find in thread no longer announces streamed count refreshes | port |
| 6f5861fa27 | #37750 | thread | fix(shared): inline code paths with spaces become file chips | ported in 93df13b9 |
| 8ca0c88cfd | #31724 | thread | fix(web): screen readers see one Notifications landmark, not two | port |
| 959f422d45 | #31676 | thread | fix(web): screen reader announcements no longer linger after they stop applying | port |
| 6e650b3849 | #31710 | thread | fix(web): returning to the window keeps a text selection | port |
| 4b758f49ec | #37813 | thread | fix(web): citation jumps move focus to the cited response | port |
| d775f6bff1 | #32371 | thread | fix(web,mobile): message timestamps follow a system time zone change | port |
| 77aaabb061 | #37879 | thread | fix(web): reveal a turn file whose path ends in whitespace | port |
| 411f0f7d87 | #30031 | thread | fix(web): make dark-mode scrollbar thumbs visible | port |
| ebd007e6ae | #37900 | thread | fix(web): View instructions closes the skill details popover | port |
| 44ebe67195 | #35300 | thread | fix(web): preserve citations when adding review comments | port |
| a2bace5cf4 | #35577 | thread | fix(web): the message minimap no longer shows a track line on themes with an opaque border | port |
| f79ab79721 | #38005 | thread | fix(web): stopped or expired questions return their attached files to the composer | port |
| d6419d92a0 | #38017 | thread | fix(web): links to repeated headings work while a reply streams | port |
| 10784e01f8 | #38041 | thread | fix: expired-session error card asks to pair again and names the rejected request's trace | port |
| 0b3ebcf268 | #38079 | thread | fix(web): sent messages keep the spaces typed at the start of a line | port |
| 1da3f3f370 | #38113 | thread | fix(web): review comments added to the chat arrive whole with their line comments | port |
| 05d3cc94b2 | #38141 | thread | fix(web): collapsing a timeline review thread no longer hits Unresolve | port |
| 68108be900 | #38250 | thread | fix(web): minimap previews show cited assistant text, not the raw link | port |
| 2df750e0c9 | #38303 | thread | fix(web): MCP app full screen header clears the native window controls | port |
| 009966d073 | #38329 | thread | fix(web): find in thread paints only matches near the viewport | port |
| 24467d671d | #38368 | thread | fix(client): a subagent prompt that opens with comment dividers no longer freezes the thread | ported (thread-3): WorkflowOpening.scriptStart without backtracking, 57.6 to 0.001 ms |
| 42763ff8b1 | #38400 | thread | fix(web): screen readers read a pull request's number once in thread details | port |
| 70e4319da8 | #38458 | thread | fix(web): switching back to a thread no longer jumps through its HTML renders | port |
| 9758cf9e13 | #38476 | thread | fix(web): typing into a simulator no longer answers a waiting question | port |
| 373ec12be6 | #38558 | thread | fix(web): very wide or tall lone images in user messages show the whole image | ported in 11fea921 |
| eb46038e3a | #38763 | thread | fix(web): Background work details show a subagent as Waiting, like the line above | port |
| 4c679a21e7 | #38832 | thread | fix(web): page scripts in inline HTML renders no longer scroll the chat | ported in d1f3d2fc |
| 245a1ead92 | #38917 | thread | fix(client): resume no longer sends a blank message to older servers | port |
| 284d3de3cc | #38963 | thread | fix(web): a thread that finished while you were away opens at its end | port |
| 94b54cfa9f | #39012 | thread | fix(client-runtime): file tooltips keep the size after workspace search | port |

## Small fixes, usage (34)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| fe219c4de1 | #24937 | usage | fix(web): keep tool groups collapsed after a usage-limit pause | left (panels-2): thread timeline, outside Features/Usage |
| 061dc79e3b | #23963 | usage | fix(usage): reject cyclic model mappings before saving | ported (panels-3): a save whose final mappings form a cycle is refused per row, UsagePriceLogic.changes |
| 06ded0b600 | #23767 | usage | fix(web): keep usage hubs that share a host | left (panels-3): hubs sharing a host is AddUsageLimitSourceDialog logic in Features/Settings, held for the Settings agent |
| 90235549bf | #23768 | usage | fix(usage): explain price edits blocked by model mappings | ported (panels-3): prices typed for a model a destination maps get "X maps this model…", UsagePriceLogic.changes |
| 87c33c8990 | #24940 | usage | fix(web): Limits ChatGPT usage card names the connected accounts | left (panels-3): the ChatGPT external-usage card listing its connected accounts needs the accounts on UsageLimitsLogic.externalUsageLinks and a line in UsageLimitsView |
| 8f258f0216 | #24630 | usage | fix(usage): use each account accent colour in limit bars | left (panels-3): per-account accent colours need ProviderEnvironmentLogic.accentColor parsed to NSColor in UsageLimitWindowBar and the pooled member bars |
| 9cee35ac4a | #21939 | usage | fix(web): accept comma as decimal in usage price entry | ported (panels-2): price entry reads the first comma as the decimal point, UsagePriceLogic.parse |
| 9f52b7d419 | #25214 | usage | fix(usage): use the freshest reported pooled plan | ported (panels-3): the freshest report naming a plan gives the merged account's plan, UsageLimitsLogic.accounts |
| b010581aea | #23411 | usage | fix(usage): combine duplicated skipped-record warnings | left (panels-3): combining duplicated skipped-record warnings needs usageFormat.ts's grouping in UsagePageView's warning list |
| 5ffcb86798 | #24260 | usage | fix(web): usage limit toast shows the Limited icon | left (panels-2): composer and thread toast, outside Features/Usage |
| 213b39198f | #25659 | usage | fix(web): composer emphasis shortcuts ignore delimiters inside inline code | left (panels-2): composer, outside Features/Usage |
| 689bdb82e9 | #23029 | usage | fix(web): usage-limit retry notice shows the timezone | left (panels-2): thread notice, outside Features/Usage |
| 31eb1d0076 | #29013 | usage | fix(web): closing Settings or Usage no longer jumps back to a quote's source | left (panels-2): thread quote navigation, outside Features/Usage |
| 58cf69c835 | #28065 | usage | fix(usage): label a proxied Claude account by its e-mail, and drop .json from hub rows | ported (panels-3): a hub e-mail replaces the driver's default instance name, and hub rows drop .json; UsageLimitsLogic.accounts |
| 3368dd70f2 |  | usage | fix(web): align usage table padding and thread status rows | port |
| 935818e422 | #25341 | usage | fix(codex): sharing usage limits offer the existing recovery options | left (panels-2): thread recovery notice, outside Features/Usage |
| c7537d0264 | #29292 | usage | fix(chat): show one usage-limit recovery notice | left (panels-2): thread recovery notice, outside Features/Usage |
| e9233b01bb | #15632 | usage | fix(web): rank usage provider summaries by the selected metric | ported (panels-2): provider summary rows rank by the shown metric, UsageMerge.rankProviders |
| 0f4a130710 | #30322 | usage | fix(codex): explain speed limits on managed connections | left (panels-3): the speed-limit explanation is in ChatGptSharingControl, a Features/Composer control held for the composer agent |
| 4c3a9d5818 | #32448 | usage | fix(cursor): use the SDK account for usage data | left (panels-3): removing Cursor's usage settings touches Features/Settings, held for the Settings agent; the meter side is free with the runtime |
| ee21337d84 | #34243 | usage | fix(shared): a zero-credit cap no longer marks seat-based Codex out of usage | ported (panels-3): a zero-credit cap no longer exhausts seat-based Codex with plan windows, UsageFallback.exhaustedWindow |
| 5099695673 | #25755 | usage | fix(web): price dialog no longer flags a model before a price is entered | ported (panels-3): a new price row shows its error only once a price or mapping is typed, UsageDialogs row |
| f28dc8ee94 | #34506 | usage | fix(cursor): unified usage plans show one meter | ported (panels-3): Cursor's Overall and Cursor Models descriptions, UsageLimitsLogic.cursorWindows |
| 489fa8c052 | #34421 | usage | fix(cursor): hide duplicate pooled usage limits | left (panels-3): hiding Cursor's duplicate total needs hasDuplicateCursorTotal in UsageLimitsLogic.displayWindows and a label-less card |
| c17ec829d0 | #35020 | usage | fix(web): overlong content search queries explain the 256-character limit | left (panels-2): files content search, see the files batch |
| d9a97e7c49 | #28703 | usage | fix(web): sidebar keeps the open thread active while Settings or Usage is open | left (panels-2): sidebar, outside Features/Usage |
| 350753afac | #35341 | usage | fix(usage): Claude accounts with a $0 monthly cap no longer leave a blank cell | left (panels-3): the $0 cap cell needs the limits' zeroSpendCap field on the wire and a dashed cell in the pooled grid |
| 46b508d119 | #23584 | usage | fix(web): keep long ACP registry searches within the query limit | left (panels-2): settings ACP registry, outside Features/Usage |
| 4192234c34 | #36561 | usage | fix(usage): distinct email-less hub accounts no longer collapse | left (panels-3): keying email-less hub accounts by a remote endpoint needs the source endpoint and host classification in UsageLimitsLogic.accounts |
| 2b596b8690 | #28581 | usage | fix(web): context meter no longer keeps the retired provider's usage | left (panels-2): thread context meter, outside Features/Usage |
| 16854a766c | #37238 | usage | fix(web): usage chart and share-bar figures reach screen readers | ported (panels-2): the chart is a group labeled like T3's sr-only caption with one row per period; the share bar's strip is hidden and its legend is a labeled list |
| b5d9c71e1c | #37241 | usage | fix(web): screen readers announce each Usage figure with its label | ported (panels-2): the drawn model and period tables expose one element per row with each figure under its column, model rows open their dialog on press; dialog stats read label and value together |
| 2579c3c4dd | #37272 | usage | fix(web): close Usage without reloading | n/a: browser history navigation |
| 310baf7c99 | #38731 | usage | fix(web): closing Settings or Usage with Esc returns focus to the opener | left (panels-3): Esc returning focus to the opener is the route modal in App, which the Settings agent changed this week |

## Skipped (32)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| d15233544e | #24013 | terminal | fix(web): keep wide characters in terminal links | skip: ghostty terminal renderer; SwiftTerm owns rendering |
| 0f6de8c22c | #23480 | terminal | fix(web): preserve Ctrl+Arrow terminal key sequences | skip: SwiftTerm owns key encoding |
| 54c1f1007c | #23493 | composer | fix(web): keep model picker open during IME composition | skip: AppKit IME handles composition |
| 645df4541b | #24016 | thread | fix(web): keep add-project inputs open during IME composition | skip: AppKit IME handles composition |
| 97dbfd72d4 | #25030 | terminal | fix(web): preserve terminal selections across unchanged redraws | skip: ghostty renderer; SwiftTerm owns selection |
| d3315d26e9 | #23231 | settings | fix(web): keep project name edits open during IME composition | skip: AppKit IME handles composition |
| d1049c4435 | #26717 | terminal | perf(web): terminal snapshots reuse WASM memory views | skip: ghostty renderer perf |
| 91f66f88de | #28298 | settings | fix(web): settings search no longer jumps or clears on an IME Enter or Escape | skip: AppKit IME handles composition |
| 4549bee918 | #21596 | terminal | fix(web): terminal types macOS Option-layer characters | skip: ghostty renderer; SwiftTerm handles Option layer |
| 6dad2adc72 | #33150 | thread | feat(cli): npx t3 offers to install the t3 command | skip: npx install prompt in hosted web empty state |
| a4c2684a0f | #30448 | thread | fix(web): project content search no longer opens a result on an IME Enter | skip: AppKit IME handles composition |
| 69c217fb15 | #30467 | composer | fix(web): an IME Escape no longer sends the file picker or content search back to the palette | skip: AppKit IME handles composition |
| dab06c0be1 | #8766 | terminal | fix(terminal): use a byte budget for Ghostty scrollback | skip: ghostty scrollback; SwiftTerm owns scrollback |
| d50a6fdc30 | #10495 | pr/git | fix(web): preview recordings stay decodable after a viewport resize | skip: browser recordings compositor, web only |
| 4c68fdcaa9 | #21641 | terminal | fix(web): the terminal cursor no longer leaves faint lines when it blinks off | skip: ghostty renderer |
| 01b815ffc2 | #34552 | terminal | fix(web): draw rounded powerline caps to fill the terminal cell | skip: ghostty renderer |
| 323c0a8d0d | #27948 | terminal | fix(web): keep wide terminal glyphs on the cell grid | skip: ghostty renderer |
| ea22b5ffc7 | #34750 | pr/git | fix(web): preview address bar waits for the IME to finish before navigating | skip: AppKit IME handles composition |
| 64959eb969 | #35210 | terminal | fix(web): terminal Ctrl+Shift+C copies on non-Latin keyboard layouts | skip: ghostty renderer |
| 729687e23c | #35468 | device | fix(web): device tab rename no longer saves on the Enter that confirms an IME candidate | skip: AppKit IME handles composition |
| 4cd7a3eb1c | #24112 | terminal | fix(web): stop opening a menu when a terminal selection ends | skip: ghostty selection menu |
| 2cb56cbf56 | #36018 | terminal | fix(web): terminal paste keeps a leading U+FEFF without bracketed paste | skip: ghostty paste |
| e096deebf6 | #28277 | pr/git | fix(web): the publish-repository path no longer submits on an IME composition Enter | skip: AppKit IME handles composition |
| 3908c4eab3 | #36777 | terminal | fix(terminal): answer OSC color queries so CLIs pick light colors | skip: ghostty; SwiftTerm answers OSC colour queries |
| 3fe1dd922d | #37066 | terminal | fix(web): terminal reports focus changes to programs that request them | skip: ghostty; SwiftTerm handles focus reporting |
| d8c7855a88 | #37148 | terminal | fix(web): terminal mouse reports hit the drawn cell | skip: ghostty |
| 7379f1969b | #37175 | terminal | fix(web): keypad navigation works with NumLock off | skip: ghostty |
| be8c4c6d9f | #37193 | terminal | fix(web): repaint terminal when programs change default colors | skip: ghostty |
| 449deb635e | #37211 | terminal | fix(web): modified F3 reaches ncurses terminal bindings | skip: ghostty |
| a3708b5180 | #37141 | terminal | fix(web): concealed terminal text stays hidden under the cursor | skip: ghostty |
| 45dbb4436c | #37223 | terminal | fix(web): legacy mouse reports reach the PTY byte for byte | skip: ghostty |
| b9bc03869e | #37206 | terminal | fix(web): terminal decorations stay visible under the block cursor | skip: ghostty |

## Free with the runtime (2)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 55e2538561 | #14693 | settings | feat(provider-kiro): add Kiro as an ACP provider | free with the runtime: new provider via server; settings list follows server catalog |
| ed5afae179 | #35869 | connections | fix(acp): v2 tool updates clear nulled fields and replace raw input | free with the runtime: ACP tool updates, server projection |

## Not applicable, judged one by one (202)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 29f33af7d7 | #26727 | thread | perf(web): long-thread timeline rebuilds 45 → 9 ms, tool updates 12 → 0.3 ms | already in CandyWrapper: entries memoized per row (TimelineEntries.Memo), see perf-sweep-4928.md |
| a03e630705 | #22352 | thread | fix(web): find in thread opens from the thread title menu, so phones can reach it | n/a: touch or phone only |
| 8084e00bce | #25204 | thread | fix(shared): stop parsing CLI flags after -- | n/a: CLI parsing, server side |
| 4e274aed25 | #23416 | thread | fix(shared): Open in Zed prefers zeditor over the ZFS zed on Linux | n/a: Linux only |
| facaa08b36 | #27097 | thread | perf(shared): SQLite reads stop queueing behind each other, up to 5x faster under load | n/a: server SQLite |
| f48fb51fac | #26777 | thread | feat(web): switch the composer between rich text and Markdown source from a button or mod+/ | n/a: reverted by #27390 |
| aa11ef6783 | #27375 | thread | fix(web): composer Markdown source button shows the pilcrow again | n/a: reverted by #27390 |
| 3dd62dce70 | #27390 | composer | revert(web): remove the composer rich text toggle button and mod+/ shortcut | n/a: revert of #26777 |
| 35c1210331 | #27354 | thread | fix: guest links can load earlier turns | n/a: web guest share page, no CW counterpart |
| 5cbc207d8c | #27420 | thread | fix(web): streaming replies no longer re-render every visible timeline row | n/a: React render perf |
| d8c926c395 | #27417 | thread | perf(web): streaming replies re-render only their last Markdown block | n/a: React render perf |
| aaee7743f8 | #27418 | pr/git | perf(web): the git actions panel no longer re-renders on every streamed update | n/a: React render perf |
| 3cbc98241d | #27419 | thread | perf(web): streamed assistant text re-renders only its own row | n/a: React render perf |
| d1f1650f09 | #23527 | composer | fix(web): keep PowerShell prompt paths with spaces in one link | n/a: Windows, Linux or Electron only |
| 8cb9182021 | #23779 | terminal | perf(client): find unread terminal chunks from the tail | n/a: client perf internals |
| 78fba059a1 | #27480 | thread | perf(web): revisiting a thread reuses its rendered Markdown instead of parsing again | n/a: React render perf |
| 5b357b3b89 | #27685 | thread | perf(web): chat Markdown parses about twice as fast with the same output | n/a: web Markdown parser perf |
| 40c0b0efe4 | #22496 | settings | fix(web): warn when ctrl shortcuts collide with mod on Windows and Linux | n/a: Windows and Linux only |
| 3776dfb4ea | #22747 | connections | fix(connect): a quit mid-download no longer wedges the relay client install | n/a: relay client install, desktop host |
| 2b1e15c999 | #23430 | thread | fix(shared): preserve hyphens in prerelease versions | n/a: server semver |
| 37022730ba | #23569 | thread | perf(web): skip favicon loading for custom project icons | n/a: web favicon perf |
| 353cf7b519 | #23640 | settings | fix(web): show project action edit buttons on touch screens | n/a: touch screens only |
| 35231d7867 | #26793 | thread | fix(web): stop timeline details icon flickering on touch devices | n/a: touch devices only |
| eb5612dda8 | #26843 | thread | fix(web): prevent long links from creating per-character elements | n/a: DOM perf |
| 1a7ddbef64 | #27069 | thread | fix(shared): preserve JSONC properties after CR comments | n/a: JSONC parser, server side |
| e9485df152 | #22340 | composer | perf(composer): reuse persisted image bytes when attachments change | n/a: web upload perf |
| cb9629e689 | #27823 | composer | perf(web): thread switches skip re-parsing, sidebar scrolling, and composer layout reads | n/a: React render perf |
| f736543c1e | #26511 | thread | fix(client-runtime): idle clients stop tracing unchanged platform registrations | n/a: tracing internals |
| aa0b3e2da6 | #27795 | thread | perf(web): the pull request timeline mounts only the events near the viewport | n/a: React render perf |
| 11df0cbc4a | #27808 | thread | perf(web): pull request comments reuse their markdown parse | n/a: React render perf |
| 54c5f25249 | #28346 | device | fix(device): use expo-device-hub 0.19.1 | n/a: device hub dependency version |
| d7a78f08a2 | #25604 | thread | fix(shared): allow atomic saves through 40 symlinks | n/a: server file writes |
| f9dd7216c0 | #23171 | thread | fix(web): keep newer titles when an untouched header rename ends | n/a: touch or phone only |
| cbd43b63d2 | #26099 | pr/git | fix(web): PR links at launch open the PR view with the local environment disabled | n/a: web/desktop launch with local env disabled |
| 0743ba5524 | #27274 | pr/git | fix(shared): branch names keep accented letters as plain letters | n/a: server branch naming |
| 6977721d00 | #27485 | thread | fix(shared): preserve escaped trailing whitespace in CLI arguments | n/a: server CLI args |
| 2f777bdd49 | #28264 | connections | perf(web): main thread updates no longer re-render an open side chat | n/a: React render perf |
| 39bca5365c | #28267 | composer | perf(web): typing in a thread no longer re-renders sidebar drafts | n/a: React render perf |
| 35df72f268 | #28270 | thread | perf(web): render minimap highlights without extra nodes | n/a: DOM perf |
| 1915569b19 | #18416 | thread | perf(client-runtime): merge shell deltas once per received batch | partly in CandyWrapper: one redraw per pull, the reducer still merges per item, see perf-sweep-4928.md |
| 21483318f2 | #18421 | files | perf(web): coalesce overlapping file tree refreshes | n/a: web perf |
| 3f105e00e3 | #21277 | thread | perf(clients): bound subagent preview processing to the visible prefix | ported (thread-3): SubagentCardRowView hoverPreview reads only to the 280-character cut |
| 7a633ce081 | #24005 | pr/git | fix(shared): keep Azure clone URLs valid when switching protocols | n/a: server clone URL |
| 35c7696790 | #24362 | thread | fix(web,mobile): time out client activity reports that never settle | n/a: web activity reporter |
| ea95364640 | #25258 | thread | perf(client-runtime): index checkpoint answers in one bounded scan | already in CandyWrapper: TurnDiffs.summaries in one pass |
| c2985a7cb5 | #26691 | terminal | perf(shared): fold command output without copying scrollback per chunk | n/a: perf internals |
| 0da2bb625c | #26720 | composer | perf(web): composer serializes each draft doc once per keystroke | n/a: web composer perf |
| 9504a09f08 | #26936 | thread | perf(clients): thread search reuses per-thread fields across keystrokes | n/a: client perf internals |
| e8b0856870 | #27041 | terminal | perf(shared): skip parsing cached terminal styles | n/a: perf internals |
| e4d1edaabd | #27073 | thread | perf(web): compact changed-file directories once | n/a: web perf |
| bd907328f3 | #27404 | thread | fix(client): a resume no longer re-renders every home row five times | n/a: React render perf |
| a98b6245eb | #27467 | thread | perf(client): avoid temporary arrays in inbox snapshots | n/a: client perf internals |
| 7c511b3d28 | #27503 | thread | fix(shared): preserve files outside log rotation naming | n/a: server logging |
| 8a18bbf281 | #27818 | settings | perf(client): repeated server settings keep the same settings object | n/a: client perf internals |
| 67ff912ccd | #28288 | thread | fix(shared): opening a database waits for another process's lock | n/a: server SQLite |
| 2101c6f619 | #28470 | composer | fix: paste-as-text shortcut on non-Latin layouts | n/a: non-Latin paste shortcut, AppKit menus handle it |
| 6879da849a | #28537 | issues | perf(shared): strip plan prefixes in linear time | ported (thread-3): ProposedPlanActions.displayed on an ArraySlice |
| 6ef66b6cd1 | #28539 | terminal | perf(shared): count terminal resume lines without allocations | n/a: perf internals |
| 0c0de57dfd | #28563 | terminal | perf(web): terminal updates no longer re-render every sidebar row and chat | n/a: React render perf |
| bcc6c08d75 | #28564 | thread | perf(web): chat view redraws no longer re-render the composer or side chat timeline | n/a: React render perf |
| f3ccba809b | #28610 | thread | fix(web): finished replies keep their hover timestamp while commands run | n/a: reverted by #29680 |
| 30084f0018 | #27833 | pr/git | perf(web): the pull request code tab derives its file model once per diff load | n/a: React render perf |
| a036489016 | #29680 | thread | revert(web): undo hover timestamp change from #28610 | n/a: revert of #28610 |
| d8a829e5ec | #29626 | pr/git | perf(web): PDF previews reload without starting a new pdf.js worker | n/a: pdf.js worker |
| f981b7a226 | #27460 | thread | perf(client): skip idle inbox placement serialization | n/a: client perf internals |
| 5fa0d0be7d | #29006 | thread | fix(clients): cancel oversized project icon responses | n/a: web favicon cache |
| 89c2a5c4dd | #29114 | thread | perf(client-runtime): expanding deferred work skips an unused timeline rebuild | ported (thread-3): with deferred work, a work page merges at its anchor only |
| efcb937695 | #29245 | composer | fix(shared): Linux file links preserve literal backslashes | n/a: Linux only |
| a6a921c763 | #29105 | thread | perf(client): streamed row updates no longer rescan question history | ported (thread-3): TimelineEntries.QuestionHistoryCache, see perf-sweep-4928.md |
| 296b089ab6 | #23373 | terminal | fix(web): terminal controls no longer cover the first line | n/a: reverted by #30493 |
| d61058debf | #29008 | thread | perf(web): reuse repeated inline skill lookups | ported (thread-3): MarkdownInlineSkills name table, see perf-sweep-4928.md |
| acad1d5a08 | #28930 | thread | perf(shared): stop single-token message search at the best hit | n/a: perf internals |
| 0a86e157a0 | #28965 | connections | perf(shared): avoid redundant visibility work on status updates | ported (thread-3): visibility fast path and a one-item isVisible, see perf-sweep-4928.md |
| 1b6336d237 | #29335 | thread | fix(shared): preserve omitted components in zero-major caret ranges | n/a: server semver |
| 2b4d6a3141 | #29457 | thread | fix(source-control): remotes like github.com:owner/repo reach their host | n/a: server remote parsing |
| 8704966861 | #29614 | pr/git | fix(shared): preview_open reports about: and mailto: as unsupported instead of misreading them | n/a: agent tool, server side |
| e1cd7f0e15 | #29730 | thread | fix(shared): accept whitespace after engine range operators | n/a: server semver |
| 76f29667c6 | #29727 | thread | fix(mcp): accept CR and mixed line endings in response streams | n/a: MCP server side |
| ebfca09e91 | #29971 | thread | perf(web): long threads stream with 70% less work-row derivation | partly in CandyWrapper: failure checks cached per revision; toolGroupAction is not, see perf-sweep-4928.md |
| 66e6217b93 | #30493 | terminal | Revert "fix(web): terminal controls no longer cover the first line" | n/a: revert of #23373 |
| c1f91b5be1 | #26806 | thread | fix(web): keep message navigation visible on touch when there is room | n/a: touch only |
| 0ea3c0243f | #27798 | pr/git | perf(pr): pull requests paint from data already held, on web, desktop and mobile | n/a: PR cache perf, web storage |
| 260d84387f | #27500 | thread | fix(shared): recognize numeric bare-repository config | n/a: server git |
| e4ff8433ee | #30479 | terminal | fix(shared): command output keeps text after an unterminated OSC | n/a: server command output parser |
| 66e96e52a4 | #30679 | thread | perf(client-runtime): stop tracing streamed thread batches | n/a: tracing internals |
| 2b0f08b524 | #30743 | thread | fix(shared): ignore unfinished quoted Git config continuations | n/a: server git config |
| cd890ba346 | #30724 | terminal | fix(shared): command output no longer prints the final byte of escape sequences with intermediates | n/a: server command output parser |
| 00d1a828ab | #30726 | thread | fix(client-runtime): sanitized error stacks keep line and column for URLs with a query | n/a: logging internals |
| 10581521d2 | #30798 | thread | fix(shared): preserve IPv6 hosts when switching clone protocols | n/a: server clone URL |
| 984fe2d45e | #32179 | usage | perf(shared): scan usage-limit support once per provider catalog | n/a: perf internals |
| 83a3674ffd | #32398 | thread | fix(web): isolate scrollbar styles from iframe owners | n/a: web iframe CSS isolation |
| ecf7f1ab95 | #27541 | sidebar | fix(web): mobile sidebar keeps its width when shelves expand | n/a: mobile web sidebar |
| 0d809db501 | #32947 | pr/git | perf(sidebar): avoid full git status for branch labels | n/a: server-side git status perf |
| c1463af205 | #28571 | thread | perf(web): changing file counts no longer re-render the chat view | n/a: React render perf |
| a0056dddb1 | #29150 | sidebar | perf(web): switching threads no longer re-renders every sidebar row | n/a: React render perf |
| dca297cd1a | #29171 | settings | perf(web): Appearance settings no longer re-probe fonts on every open | n/a: web font probe perf |
| 2dc07510e2 | #30038 | issues | perf(web): long reasoning previews format in linear time (600 ms → 1.3 ms median) | ported (thread-3) in kind: liveThoughtLine reads a 1,024-character prefix, see perf-sweep-4928.md |
| cddfc8db21 | #30714 | composer | fix(composer): bound long path search requests on web and mobile | n/a: web request bounding |
| 077fd62222 | #33503 | thread | fix(client): finishing a long background thread no longer freezes the app | n/a: web main-thread yield |
| 9e12eca125 | #33643 | thread | fix(shared): relative Windows file links open the file | ported in 93df13b9 |
| 65ffcbf647 | #33438 | thread | perf(shared): speed up escaped Markdown in long PR descriptions | already in CandyWrapper: keepingWindowsPathEscapes is a linear byte scan |
| 56064fc4f6 | #33325 | sidebar | fix(ssh): Intel Mac hosts no longer try to download a missing t3 archive | n/a: SSH host install, server side |
| fa2f4ff2a2 | #33066 | browser | fix(web): panel resize handles follow touch drags | n/a: touch drags |
| 05020d6fa9 | #34002 | thread | perf(client): reopening a finished command row no longer refetches its output | ported (thread-3): finished command output stays 5 minutes after its row hides |
| ba4d01cf7f | #32646 | connections | fix(shared): login-shell environment probe ignores DEBUG trap output | n/a: server shell probe |
| 4363d0bf65 | #32963 | thread | fix(web): mouse tilt wheel no longer switches threads on Windows and Linux desktop | n/a: Windows and Linux |
| 2163d41409 | #33479 | thread | fix(shared): Open in Zed ignores the OpenZFS zed daemon on Linux | n/a: Linux only |
| 52d621a6f1 | #21661 | files | fix(desktop,web): Open in runs locally for a background service sharing the desktop's T3 home | n/a: web desktop shared home |
| e0379fbf5c | #23001 | pr/git | fix(web): collapsed reasoning previews no longer process the whole block | n/a: web perf |
| ad0b2a9d2f | #27425 | files | perf(client): streamed text no longer republishes thread queue and checkpoints | already in CandyWrapper: streaming-only updates skip the composer (ThreadSession onProjection) |
| 0629735d37 | #27490 | sidebar | fix(web): thread controls hide while the mobile sidebar is open | n/a: mobile web sidebar |
| 4eb20e4d38 | #33829 | thread | fix(shared): clicked HTML images keep whole emoji in capped names | n/a: HTML render internals |
| 96a2f0a776 | #27426 | connections | fix(shared): relay client install survives antivirus-slowed first launch | n/a: relay client install, desktop |
| f89af364ec | #34315 | pr/git | fix(web): avoid false errors when cancelling preview popouts | n/a: web picture-in-picture |
| c2ff84a4bb | #34311 | issues | fix(client): trim model-reference delimiters in linear time | n/a: perf internals |
| 3d12c90ea8 | #34340 | thread | perf(shared): avoid quadratic file link labels | ported (thread-3): FileLinks.parentSuffixes counts suffixes once, 107.0 to 3.3 ms for 800 files |
| cd8fc91a57 | #27557 | browser | fix(web): don't offer VS Code on iPad, iPhone and Android browsers | n/a: mobile browsers |
| 6b2591b252 | #34857 | thread | fix(source-control): a query or fragment after .git keeps the repository identity | n/a: server git identity |
| 71dfe27e45 | #35174 | sidebar | fix(web): an untouched sidebar thread rename keeps a title that arrived while it was open | n/a: touch or phone only |
| 7ab11f1871 | #35442 | sidebar | fix(web): narrow-window sidebar sheet obeys disabled panel animations | n/a: narrow web sheet |
| 3c9a54979a | #35502 | thread | fix(grok): Grok MCP calls store the real tool, arguments, and result | n/a: server tool output |
| cf82fb8584 | #35322 | thread | fix(shared): preserve repository paths when switching clone protocols | n/a: server clone URL |
| a03f7185f2 | #33956 | files | perf(web): PDF Find jumps to the first match in long PDFs 3.1x faster (median) | n/a: pdf.js perf |
| 6d535841a3 | #29306 | thread | fix(web): a chunk that fails after boot no longer reloads the page in a loop | n/a: web chunk reload |
| f41e8b3c10 | #27851 | composer | fix(shared): Windows-style paths stay out of the slash menu | n/a: Windows paths |
| e1d59d1884 | #29959 | thread | fix(web): the collapsed mobile composer shows Stop while a turn runs | n/a: mobile composer |
| ff045198dc | #35666 | pr/git | fix(web): PDF preview prerenders pages two viewports below the visible area | n/a: pdf.js prerender |
| f6787e8537 | #24121 | thread | fix(web): reuse timeline rows while thinking and plans stream | n/a: React render perf |
| bb9658d3a7 | #26935 | thread | perf(shared): command output failure scan rejects clean output in one pass | already in CandyWrapper: one ICU alternation cached per item revision |
| 2755a951a1 | #35806 | thread | fix(web): "Try again" recovers from a failed page chunk load | n/a: web chunk reload |
| 36371de910 | #35815 | thread | fix(shared): read MCP event streams whatever the case of the content type | n/a: MCP server side |
| 87a772a3c6 | #29496 | composer | fix(web): opening a thread on a touch tablet no longer focuses the composer | n/a: touch tablets |
| 082a3e3c52 | #36085 | thread | fix(web): narrow-window right panel dialog is named Workspace panel | n/a: narrow web sheet |
| daed91f264 | #36067 | thread | fix(shared): batch SQLite worker result transfers | n/a: server SQLite |
| fa6326bf1b | #36325 | composer | fix(web): closing a composer menu on a touch tablet no longer opens the keyboard | n/a: touch tablets |
| 7ea6db49e4 | #36390 | thread | fix(web): a mounted chat view no longer keeps every thread copy it replaced | n/a: web memory internals |
| 3c1be119b9 | #36436 | terminal | fix(web): middle-clicking empty chat space on Linux no longer pastes into the composer | n/a: Linux middle-click paste |
| 7ae21bf164 | #28469 | thread | fix(web): don't label Windows paths outside the workspace as relative | n/a: Windows paths |
| 525f5b2f6d | #24319 | usage | fix(usage): count shared Windows and WSL transcripts once | n/a: server usage merge |
| 44a8e9541b | #34964 | settings | fix(web): model settings no longer re-render every row on each star, toggle or move | n/a: React render perf |
| 6bc105f04e | #23743 | thread | fix(editors): find JetBrains IDEs whose Toolbox script is named idea1 | n/a: JetBrains discovery, server side |
| d9619adc09 | #27479 | connections | fix(web): stop offering T3 Connect routes for the desktop's own WSL backend | n/a: Windows WSL |
| 56fd98be52 | #36166 | composer | perf(web): batch first-send composer updates | n/a: React render perf |
| 9803d1adb5 | #36042 | settings | fix(web): paint the selected environment theme from the first frame on launch | n/a: web first paint |
| 388424db26 | #35617 | thread | fix(shared): capture shell values after profiles replace PATH | n/a: server shell probe |
| 294e061a20 | #36547 | connections | fix(shared): IPv6 SCP remotes match SSH repository identities | n/a: server git |
| 4d5d5f89d4 | #36576 | pr/git | fix(source-control): preserve .git in Azure DevOps repository names | n/a: server git |
| a61291e3e2 | #24006 | thread | fix(shared): one-letter link schemes no longer become file links on Windows | n/a: Windows paths |
| 4c2f04d35d | #24055 | composer | fix(web): queued runs, relationships and changed files no longer re-render on every streamed token | n/a: React render perf |
| 0200dcf242 | #27979 | composer | perf(shared): queued SQLite reads stop waiting on one reader while another is free | n/a: server SQLite |
| e72dd5055e | #36647 | terminal | fix(client): closed terminal views release the shared grid | n/a: web terminal grid |
| 07885556d9 | #29376 | thread | fix(shared): honor Windows PATHEXT regardless of key casing | n/a: Windows PATHEXT |
| 043d712294 | #33250 | thread | fix(shared): atomic saves handle long filenames | n/a: server writes |
| b779d40077 | #33461 | thread | fix(editors): Open in Zed no longer finds the ZFS event daemon | n/a: Linux only |
| dd5061364b | #33794 | thread | perf(web): completed Markdown blocks no longer render twice | n/a: React render perf |
| f968db10d7 | #33435 | composer | perf(web): opening a thread from a draft only renders its sidebar row | n/a: React render perf |
| ccf7ead6a4 | #33840 | thread | fix(shared): preserve whitespace in POSIX PATH directories | n/a: server shell probe |
| 6ea5af70ad | #34397 | issues | perf(web): trim terminal link delimiters in linear time | n/a: perf internals |
| d38055656e | #34301 | pr/git | perf(web): skip oversized TAR preview payload copies | n/a: web perf |
| 20ee041354 | #22795 | composer | fix(web): font picker scrolls to every font in short windows | n/a: Windows, Linux or Electron only |
| 19c9df2161 | #30394 | diff | fix(web): diff Copy path uses Windows separators in a Windows workspace | n/a: Windows paths |
| 9ca66225ca | #36973 | browser | fix(web): app loads in browsers without URL.canParse or URL.parse | n/a: old browsers |
| c0561c5c3d | #30818 | thread | fix(shared): the SQLite reader pool comes back after a failed start | n/a: server SQLite |
| 33f8c5da29 | #30718 | thread | fix(web): keep history-placed guest messages out of the footer | n/a: web guest page |
| 1ba934798f | #36977 | thread | fix(shared): keep Windows path separators beside ampersands | n/a: Windows paths |
| ec844a3995 | #30940 | connections | fix(client-runtime): omit machine labels from relay spans | n/a: tracing internals |
| a6d7695064 | #36995 | diff | perf(web): collapse all no longer remounts the diff viewer | n/a: React render perf |
| 0983ab3e73 | #36999 | composer | fix(web): choosing a provider in the model picker no longer raises the phone keyboard | n/a: phone keyboard |
| cef95b6db9 | #37004 | sidebar | fix(shared): decode URI paths in ghq clone folders | n/a: server clone folders |
| 48a383ca6f | #31324 | thread | fix(web): show failed desktop downloads in retry tooltips | n/a: Electron desktop updater |
| a96bb81049 | #37002 | pr/git | perf(right panel): normalize pr tab target once | n/a: perf internals |
| 47f2e91210 | #37001 | thread | perf(web): batch middle truncate fits | n/a: web perf |
| 1c86881dd5 | #31465 | diff | perf(web): Expand all folders in the diff file tree no longer rescans every folder for each expansion | n/a: web perf |
| bee9eb5939 | #31781 | connections | fix(shared): recognize SSH remotes with a single path component | n/a: server git |
| 6615615b12 | #31788 | thread | fix(shared): preserve Git remote headers after comments | n/a: server git |
| 2e0353daae | #32169 | thread | fix(shared): compare prerelease versions without locale or precision loss | n/a: server semver |
| 137a869138 | #29710 | pr/git | fix(shared): use HTTP for schemeless loopback previews | n/a: server preview URL |
| 32a6a7f70b | #26612 | thread | fix(web): desktop window recovers when its backend restarts during a renderer reload | n/a: Electron renderer reload |
| e2afd2546e | #32323 | composer | perf(web): typing no longer re-renders the composer's footer controls | n/a: React render perf |
| 4117bd42ec | #32324 | thread | perf(web): answering a question no longer re-renders the whole chat view | n/a: React render perf |
| 528c77fe83 | #32657 | thread | fix(shared): .localdomain hosts no longer leak to the favicon service | n/a: server favicon service |
| 7f575e6328 | #32619 | connections | fix(web): collapsing Electron main no longer hides the backend server | n/a: Electron diagnostics |
| 2045004096 | #32178 | thread | fix(shared): keep coalescing workers alive when processors throw | n/a: server worker |
| 789d10fb54 | #37151 | settings | fix(web): Sharing & access can select a desktop-local WSL backend | n/a: Windows WSL |
| a16796b956 | #37152 | pr/git | fix(shared): ß no longer splits words in generated folder and branch names | n/a: server naming |
| cb251b9abc | #37179 | composer | fix(web): composer suggestions stay reachable in short windows | n/a: Windows, Linux or Electron only |
| 14f295e011 | #37233 | terminal | fix(terminal): one web viewer answers shared PTY queries | n/a: web terminal viewers |
| 5a20d59db3 | #37632 | thread | fix(shell): Windows PATH probe reads User and Machine registry | n/a: Windows PATH |
| f6d196463c | #37872 | thread | fix(shared): stopping an MCP call cancels its stalled SSE response | n/a: MCP server side |
| f0572cf1b9 | #37892 | connections | fix(source-control-bitbucket): read ssh.bitbucket.org remotes as Bitbucket Cloud | n/a: server clone URL |
| 48359de5f4 | #38025 | thread | fix(shared): stopping an MCP call releases a stalled JSON response body | n/a: MCP server side |
| b91ea5443c | #38193 | thread | fix(shared): keep Unicode whitespace in launch argument values | n/a: server CLI args |
| 38f7761148 | #38238 | thread | fix(shared): keep literal quotes in POSIX PATH directories | n/a: server shell probe |
| 1063b42768 | #38249 | issues | fix(shared): large MCP SSE results in small chunks parse in linear time | n/a: MCP server side |
| 74b1f97ce9 | #38281 | settings | fix(web): reopening Settings reloads WSL distributions | n/a: Windows WSL |
| 51eb2d5437 | #38332 | usage | fix(web): usage chart's screen-reader caption stays hidden in Firefox | n/a: Firefox |
| 03822a8312 | #38540 | pr/git | fix(shared): Latin letters such as ł, ø, þ and ı no longer split words in generated folder and branch names | n/a: server naming |
| 3088d26665 | #38546 | thread | fix(web): thread details rows no longer show stray scrollbars on touch screens | n/a: touch screens |
| 3ce2145864 | #29399 | connections | feat(fx): add safe CLI updates with cancellation compatibility | n/a: server process updates |
| 20668e8ece | #38823 | files | fix(shared): ŉ no longer splits a word in project folder names | n/a: server naming |
| 410109da5d | #38804 | thread | fix(testing): test git commands stay out of the outer repository | n/a: test tooling |
| 158394194c | #38898 | terminal | fix(shared): html_render cards show for Antigravity's acp-mcp-call terminal fallback | n/a: server tool output |

## Not applicable in bulk: tests, refactors, chores, and mobile, desktop or server-only scopes (242)

| Commit | PR | Area | Change | Status |
|---|---|---|---|---|
| 612a8e59f0 | #18642 | - | feat(mobile): add dynamic workflows to the Agents sheet | n/a: mobile only |
| 8ff9ae1f87 | #26739 | - | fix(mobile): delivered messages no longer reappear at the bottom of long threads | n/a: mobile only |
| da1eab01f7 | #26167 | - | chore: make agent mistakes fail early | n/a: chore |
| b5fc7bedfe | #26893 | - | feat(release): release notes and the update popover open with a short note | n/a: release only |
| 3748c5c241 | #26921 | - | test(web): pin the npm wait floor for update everything | n/a: test |
| 505d02282f | #23848 | - | fix(gitlab): accept merge request URLs from self-hosted hosts | n/a: tests only |
| 1d631342b0 | #22883 | - | fix(markdown): formulas ending in a comma render | n/a: tests only |
| 12bd9d6a61 | #25219 | - | fix(mobile): list pull request repositories once per environment | n/a: mobile only |
| a1621a81af | #25225 | - | fix(server): show MCP App forms from failed tool results | n/a: server only |
| cb5fac907a | #24080 | - | fix(server): mark unread no longer brings back a dismissed wake | n/a: server only |
| 44d508fd8b | #27239 | - | feat(server): `t3 service protect` keeps the server alive when agents fill memory | n/a: server only |
| 6b1245cced | #27252 | - | fix(server): Stop always completes, and an agent that ignores it can be force stopped | ported: the thread's now lines show Stopping with its time, and Agent not responding to Stop with Force stop once the request has `unresponsiveAt`, behind `threadForceStop` (thread-2, T3Store `RunStop`, ComposerController `forceStop`) |
| 476590d0ad | #27430 | - | feat(desktop): back/forward buttons and trackpad swipe navigation | n/a: desktop only |
| e4ecaf629d | #27373 | - | feat(mobile): message media, file cards and grouped steers match web | n/a: mobile only |
| 028ed851d5 | #19066 | - | fix(server): Codex generated images show in chat, including on Android with a Windows host | n/a: server only |
| ece8fd8e8c | #22893 | - | fix(markdown): an escaped backslash before \( no longer crashes dev builds | n/a: tests only |
| 8bbe5aa384 | #23464 | - | fix(mobile): share pull request refresh subscriptions | n/a: mobile only |
| d18690dadc | #23677 | - | fix(observability): trace attributes keep objects that appear twice | n/a: observability only |
| 8689c7a4f5 | #23747 | - | fix(server): onboarding reads a remote url on its section header line | n/a: server only |
| 7ec1894eb5 | #27125 | - | fix(desktop): control sockets work with long temporary paths | n/a: desktop only |
| 81899ce04c | #27746 | - | feat(server): read Bitbucket and GitCafe credentials from a secret provider | n/a: server only |
| 3e42e668c4 | #26643 | - | fix(mobile): reconnecting threads no longer open on "Failed to connect" | n/a: mobile only |
| 53a986eb49 | #27904 | - | fix(server): keep connection tickets out of request traces | n/a: server only |
| 6d46336476 | #27986 | - | fix(observability): redact credential URL params in spans and type them as Redacted | n/a: observability only |
| bf8e132439 | #27893 | - | fix(server): preview discovery stops sending HTTP and TLS to agent-started ports | n/a: server only |
| b970bcb34b | #22442 | - | fix(opencode): use Big Pickle for default text generation | n/a: tests only |
| b8ca826bf6 | #22302 | - | fix(server): preview status and snapshot never echo a data: page's contents | n/a: server only |
| e8b877c547 | #23177 | - | fix(observability): record OTLP/JSON spans that leave out empty fields | n/a: observability only |
| cbb0417df5 | #27662 | - | fix(mobile): resume continues a usage-limited thread before its queue | n/a: mobile only |
| 460b88bc42 | #28593 | - | feat(release): update notes lead with up to 7 highlights | n/a: release only |
| 8b4de61b8b | #28556 | - | fix(desktop): discover shell environment without blocking startup | n/a: desktop only |
| 976a23161d | #26485 | - | fix(mobile): thread links show their thread's title | n/a: mobile only |
| 57d764ea1a | #28834 | - | fix(web): ChatView browser test no longer times out on CI | n/a: tests only |
| 123e5ba065 | #7295 | - | fix(server): force-stop timed out login shell probes | n/a: server only |
| f2dd1a4468 | #26920 | - | test: remove unreachable sidebar helper suites | n/a: test |
| 01a93e7b51 | #28887 | - | test(web): pass stale to the stack menu refusal test | n/a: test |
| 6b3b3b75bd | #27131 | - | fix(web): chat text can be cited while file search is open | n/a: tests only |
| 0bccd293cf | #27286 | - | fix(desktop): disable blocked t3 CLI installation | n/a: desktop only |
| 9b7208832e | #27399 | - | fix(server): show why Codex hooks stopped a turn | n/a: server only |
| a0d08d7550 | #24494 | - | fix(server): saving a shortcut no longer deletes rules it can't read | n/a: server only |
| 7a760a9a88 | #28715 | - | fix(desktop): load the renderer while the backend starts | n/a: tests only |
| 0c4454ca6a | #29026 | - | perf(server): Codex calls t3_thread_wait directly instead of from Code Mode | n/a: tests only |
| 23075af981 | #29068 | - | refactor(server): name Codex's direct-only T3 MCP server t3-code-direct | n/a: refactor |
| 0338e99fe3 | #29079 | - | fix(desktop): save and copy any image the app can show | n/a: desktop only |
| 8657eecb28 | #29432 | - | fix(server): defer Tailscale endpoint discovery during startup | n/a: server only |
| 84537c4dd9 | #27756 | - | feat(server): read source control host tokens from a secret provider | n/a: server only |
| 57cd05904d | #26833 | - | chore(deps): upgrade Effect to 4.1.2 and alchemy to beta.85 | n/a: chore |
| 2d2299aaaf | #29813 | - | fix(web): file save session browser test no longer hangs on the discovery poll | n/a: tests only |
| 7681605d73 | #29911 | - | fix(server): t3 update installs from the policy's update mirror | n/a: server only |
| dd24b375f0 | #30319 | - | fix(desktop): a policy that stops startup no longer points at another release | n/a: desktop only |
| d1ec71e6ff | #26734 | - | feat(mobile): add on-device Android dictation | n/a: mobile only |
| a10490937d | #27760 | - | feat(server): read usage limit source keys from a secret provider | n/a: server only |
| da3f97299f | #27938 | - | fix(server): startup no longer hangs on a shell stuck in the kernel | n/a: server only |
| cedcc31096 | #29786 | - | fix(server): OTLP export settings survive a saved token streaming mode | n/a: server only |
| fcad9de8ce | #30350 | - | test(web): file editor dismissal test waits for the editor to render | n/a: test |
| fb8e6d8656 | #30404 | - | test(web): worked-for heading test clicks once the list is revealed | n/a: test |
| 19a2bad155 | #29763 | - | fix(azure-devops): legacy DefaultCollection pull request URLs can be pasted to check out | n/a: tests only |
| 40aba09b44 | #29892 | - | fix(github): Enterprise Server pull request URLs can be pasted to check out | n/a: tests only |
| 8bc344bd9c | #30174 | - | fix(server): read continued core.bare values during onboarding | n/a: server only |
| 2863eded44 | #29853 | - | fix(server): deleting a thread also removes its agent preview recordings | n/a: server only |
| 737afe24bd | #30560 | - | fix(server): retry unstarted runs after recovery | n/a: server only |
| 95e53a54db | #31028 | - | build: typecheck with tsrs and Effect's rules through @effect/tsgo | n/a: build |
| 14e8f393fa | #30474 | - | refactor: replace jose with effect/jose | n/a: refactor |
| fb99a5e4b0 | #30501 | - | refactor: move HMAC, key, and random work to effect/crypto | n/a: refactor |
| 33ba7bf5ef | #30529 | - | refactor: hold relay signing keys in EnvironmentSigningKey and CloudMintSigner | n/a: refactor |
| a07be97ab0 | #30540 | - | refactor(client-runtime): share DPoP proof creation across web and mobile | n/a: refactor |
| 7f6f47b27b | #31104 | - | test(web): PDF preview tests wait on pdf.js loads and stop timing out | n/a: test |
| a21d788752 | #29803 | - | feat(server): render MCP Apps from Claude tool calls | n/a: server only |
| 4b87a45770 | #31111 | - | build: run Effect rules on mobile and lock in clean suggestion rules | n/a: build |
| 2ef6435f50 | #24186 | - | fix(server): idle agent tabs free a slot when the server's 32-tab browser limit is full | n/a: server only |
| e4e3657344 | #28928 | - | fix(mobile): configure another Claude account from Providers | n/a: mobile only |
| 754e1d1534 | #27935 | - | fix(mobile): compact stale Claude threads before sending | n/a: mobile only |
| 5a906583fe | #31217 | - | refactor: Effect.try calls map failures to typed errors | n/a: refactor |
| 298cb24140 | #31216 | - | refactor: errors are Schema.TaggedError, not Data.TaggedError or native Error | n/a: refactor |
| 66633fb682 | #31300 | - | fix(mobile): transcribe Android audio during recording | n/a: mobile only |
| bf5485c2e9 | #26492 | - | test(web): linked-environment subagents keep opening in their own thread | n/a: test |
| 53c26b12db | #29661 | - | test(web): worked-for expand test waits for the timeline to finish loading | n/a: test |
| 0d3b01a888 | #29933 | - | test(web): avoid PDF worker startup timeouts in attachment tests | n/a: test |
| e402c94034 | #30372 | - | test(web): source control writing settings test waits for the reset button | n/a: test |
| 6bd73c3662 | #30613 | - | test(web): keep the work heading test inside the viewport | n/a: test |
| c72de5249a | #30817 | - | test: remove stale tests for unused thread and onboarding helpers | n/a: test |
| 0f28f6f6a0 | #31709 | - | feat(mobile): start side chats with /side | n/a: mobile only |
| b8dce83214 | #30625 | - | feat(server): transcribe audio on a chosen environment | n/a: server only |
| aabd5629c9 | #30624 | - | feat(desktop): dictate into browser annotations with the same consent | n/a: desktop only |
| 2917f28465 | #28487 | - | perf(mobile): faster thread sync, connects, and reconnects on bad wifi | n/a: mobile only |
| 42a0e917cf | #30524 | - | feat(gitlab): link issue, merge request, commit and user references | n/a: tests only |
| cedaa0de48 | #19288 | - | perf(server): Windows git reads no longer start a console host | n/a: server only |
| 9ef12568cb | #31804 | - | fix(server): keep writes moving with a larger WAL limit | n/a: server only |
| 98b930f932 | #31801 | - | fix(mobile): keep the opening words of local iPhone dictation | n/a: mobile only |
| ccde655b8f | #28223 | - | fix(desktop): let the window shrink to 400x360 so it fits half-screen tiles | n/a: desktop only |
| dd059b40bc | #31857 | - | feat(server): stop opted-in project actions when threads settle | n/a: server only |
| 67fdc53823 | #26324 | - | fix(desktop): published themes reach the app when it uses this machine's service | n/a: desktop only |
| ea9fbc1a07 | #23486 | - | fix(desktop): open cursor:// and vscode:// file links from chat | n/a: desktop only |
| 9557ab46c5 | #32287 | - | perf(mobile): thread list resumes from the saved cache, and large gaps reload over gzip HTTP | n/a: mobile only |
| b7d33af938 | #32927 | - | perf(server): macOS worktrees open 2x faster by cloning a cached checkout | n/a: server only |
| 9028d760b4 | #29598 | - | feat(mobile): long-press an image to save it to Photos | n/a: mobile only |
| 920ffcdd04 | #33139 | - | test(web): OpenInPicker announcement test no longer hears the previous test | n/a: test |
| 3dc54f43df | #33153 | - | feat(desktop): a fresh install sets up the t3 command | n/a: desktop only |
| 202e8ef77c | #27353 | - | fix(web): Markdown tasks no longer stay checked after their source is unchecked | n/a: tests only |
| 9fcfd4c16e | #33093 | - | feat(source-control): add Cursor Origin provider | n/a: tests only |
| 445efb6dfc | #31998 | - | perf(mobile): sign DPoP proofs natively, up to 355x faster on Android | n/a: mobile only |
| 4df0c1302a | #28125 | - | refactor: upgrade Legend List to 3.7.2 and drop our list workarounds | n/a: refactor |
| 60514be911 | #24079 | - | fix(server): phones get the approval push when a subagent waits | n/a: server only |
| cd87cce900 | #33255 | - | fix(server): include thread titles in MCP links | n/a: server only |
| dc3fdc6a3e | #33306 | - | perf(mobile): threads open over the socket without an extra HTTP round trip | n/a: mobile only |
| d3e0e8b8ab | #30456 | - | refactor(shared): simplify remote branch filtering | n/a: refactor |
| d655e2cca6 | #33627 | - | chore(web): upgrade @pierre/diffs to 1.7 and use its built-in find | n/a: chore |
| e6fa2e35c3 | #33629 | - | fix(web): expanding hidden diff context works after a diff refresh | n/a: tests only |
| b718643e83 | #33867 | - | test: remove redundant short-string truncation test | n/a: test |
| 8ee7183e6c | #33964 | - | test(web): minimap next-turn test no longer flakes after a resize | n/a: test |
| 524a53183d | #33957 | - | fix(mobile): tool call commands are highlighted and monospaced like on web | n/a: mobile only |
| 44ebb2fe57 | #33800 | - | feat(usage): show Muse Code limits, and xAI and Antigravity accounts from a CLIProxyAPI hub | n/a: tests only |
| 79bca436b2 | #34096 | - | feat(server): voice models reuse copies already on disk | n/a: server only |
| 0f13d2ccbd | #33985 | - | refactor(web): remove icon morphing | n/a: refactor |
| c03f84bcde | #34030 | - | fix(server): stream the usage-scan cache to disk instead of one string | n/a: server only |
| 42185a6206 | #34191 | - | test(web): right panel tab swipe test runs as macOS on any CI host | n/a: test |
| 37452eeaa3 | #33439 | - | fix(server): cloning into a stranded clone project's empty folder reuses that project | n/a: server only |
| e93f6ea361 | #22960 | - | fix(desktop): Cmd+F now searches the page in the integrated browser | n/a: desktop only |
| f6433dba45 | #34192 | - | fix(desktop): an SSH password prompt that ended leaves the dialog instead of stacking | n/a: desktop only |
| 75c7fb28af | #22155 | - | fix(server): imported ACP sessions show their native history | n/a: server only |
| 5da53f87d9 | #26763 | - | fix(server): CLI commands no longer migrate the database of a running server | n/a: server only |
| 49013438a9 | #34170 | - | test: remove tests that repeat another case or restate the source | n/a: test |
| fb7e558943 | #34417 | - | test(web): theme search test no longer flakes on slow runners | n/a: test |
| 9cb45ec0b7 | #28918 | - | fix(server): text generation falls back to an enabled custom instance instead of a disabled default | n/a: server only |
| 9ef259e517 | #33188 | - | fix(mobile): sidebar empty states and repeated usage notices | n/a: mobile only |
| 462eeac63b | #34263 | - | fix(mobile): stale Claude threads show a compact-before-send notice | n/a: mobile only |
| fcc25c8bb2 | #34554 | - | ci: split web tests over two runners so every run finishes sooner | n/a: ci |
| e63d80a065 | #34586 | - | test(web): check custom worksheet targets at the preparation layer | n/a: test |
| 3a25643192 | #34578 | - | fix(contracts): Open in VS Code keeps a plus in the SSH username | n/a: tests only |
| de26b6db3c | #32702 | - | fix(server): providers read cited assistant text again | n/a: server only |
| c7618f6c10 | #34597 | - | fix(server): a steer that cuts off a streaming Claude reply marks it interrupted | n/a: server only |
| b3ce149be5 | #29761 | - | fix(mobile): Fast can be turned on for an existing thread | n/a: mobile only |
| a2a3388c5e | #23496 | - | fix(server): keep writes moving while readers pin the WAL | n/a: server only |
| c8ddb2203e | #26172 | - | fix(desktop): middle-click paste follows gtk-enable-primary-paste on Linux | n/a: desktop only |
| 6eef4acced | #33169 | - | feat(mobile): switch the settings language | n/a: mobile only |
| 7d71f852a8 | #34431 | - | fix(mobile): screen readers hear when the open thread needs you or finishes | n/a: mobile only |
| d353fba97e | #26244 | - | fix(desktop): stalled update downloads time out and say why | n/a: desktop only |
| b75f117aa1 | #23610 | - | fix(server): Rescan finds tools installed after T3 Code started | n/a: server only |
| 7a39060072 | #35057 | - | fix(server): a damaged state database fails startup with its path and how to recover | n/a: server only |
| 5fae2b5124 | #35107 | - | test(web): command palette tests clear a leaked last-used project | n/a: test |
| 8f54d4b1a9 | #35097 | - | fix(desktop): exits that skip quit are recorded in the trace and logs | n/a: desktop only |
| e89c8ce014 | #35114 | - | fix(server): a file ticked Viewed before loading a push shows Changed | n/a: server only |
| 8b2763f638 | #35072 | - | perf(mobile): each environment sends about 85% less data at launch | n/a: mobile only |
| fc6c7c8b27 | #35179 | - | fix(server): usage model details count the real unpriced tokens | n/a: server only |
| 65c0195b46 | #34596 | - | fix(mobile): the thread list no longer reshuffles once per environment on startup | n/a: mobile only |
| 476fc9be66 | #35225 | - | test(server): wire budget measures what clients fetch today, and the PR comment shows every row | n/a: test |
| 2b4a9c744e | #35361 | - | test(web): inline confirm tests no longer race the 3s disarm timer | n/a: test |
| 69dd4d08ea | #35360 | - | test(web): Add Environment dialog test fills fields instead of typing each key | n/a: test |
| 4e48d9e6a5 | #35359 | - | test(web): HTML preview accordion test waits for the frame's script before it toggles | n/a: test |
| c5f5efdbd2 | #35391 | - | fix(server): text-generation fallback keeps the thread default's custom model | n/a: server only |
| 4ca5b9cdb8 | #35486 | - | fix(server): long startup migrations log progress and resume after a restart | n/a: server only |
| 444ea535e3 | #35563 | - | test(web): split the cloud voice settings flow into independent cases | n/a: test |
| 63edc304c0 | #35556 | - | fix(desktop): SSH suggestions from known_hosts keep their port | n/a: desktop only |
| e9a7c076f7 | #35581 | - | test(web): OpenRouter voice test fills the model picker instead of typing each key | n/a: test |
| d8f3feff0c | #35586 | - | test(web): Mermaid rejection test waits for the viewer chunk to load | n/a: test |
| 0d51d5bf6d | #35543 | - | fix(server): a server published through Tailscale Serve no longer reports itself as local-only | n/a: server only |
| 95f164d083 | #35646 | - | test(web): Mod+E bold-word test no longer drops its first arrow key | n/a: test |
| 18aeb0fb91 | #33687 | - | fix(server): new worktrees show submodule downloads instead of a stuck checkout | n/a: server only |
| bce2bc048e | #35665 | - | test(web): split the cloud voice cancel flow from the failed-then-saved setup | n/a: test |
| d76e06679b | #35661 | - | fix(server): snooze no longer waits two minutes after a steered queued message | n/a: server only |
| 2e741fc089 | #35056 | - | fix(desktop): wait for the server's database upgrade instead of reporting a failed start | n/a: desktop only |
| 587deab7d3 | #34128 | - | feat(server): keep the computer awake while agents work | n/a: server only |
| d4b77d2448 | #26668 | - | fix(server): Claude background commands show how long they have run | n/a: server only |
| 36254ab82e | #33214 | - | fix(server): a watched PR stops holding its thread once its checks finish | n/a: server only |
| ce268642cc | #35728 | - | fix(server): a slow database write no longer freezes the server | n/a: server only |
| d86ee1e261 | #34061 | - | test(web): typecheck the project file refresh test | n/a: test |
| 5ccc65be0a | #35803 | - | test(web): sidebar drag test opens its folder past the shift guard | n/a: test |
| 95cb068c10 | #35817 | - | test(web): sidebar drag test ignores a fading row clone after folder collapse | n/a: test |
| e079ad9a85 | #23141 | - | fix(desktop): clicking inside the in-app browser closes open host menus | n/a: desktop only |
| d6fc871b58 | #29452 | - | fix(desktop): update browser tab titles without navigation | n/a: desktop only |
| 43ce39595b | #35868 | - | test: run clock-free live tests on TestClock | n/a: test |
| ee645553a9 | #35993 | - | test: drop Effect.scoped wrappers that @effect/vitest already applies | n/a: test |
| 4596872940 | #35865 | - | perf(server): linked-thread counts update when links change instead of polling every 10s | n/a: server only |
| eb7e63a822 | #35858 | - | fix(server): thread reads preview linked PRs and list_thread_pull_requests pages | n/a: server only |
| d19467a59e | #36233 | - | fix(server): a thread visit stores only its read state | n/a: server only |
| ff30b16af4 | #36266 | - | fix(desktop): clicking above the Settings or Usage modal closes it again | n/a: desktop only |
| 065aca4889 | #36269 | - | test(web): code block highlight test waits for the highlighter, not a 1s poll | n/a: test |
| 65e4272db1 | #36327 | - | fix(server): a hung network mount no longer freezes the server when it spawns a process | n/a: server only |
| aab388ddb1 | #36384 | - | fix(server): Claude can show the user mid-turn text in full | n/a: server only |
| eea9d15ee2 | #30037 | - | fix(desktop): Windows folders dropped on a WSL backend insert their WSL path | n/a: desktop only |
| a760a3a965 | #24889 | - | fix(desktop): keyboard-opened message link menus select their first item | n/a: desktop only |
| 86d49daf82 | #24656 | - | fix(server): open stable Zed when a prerelease Zed is first on PATH | n/a: server only |
| c0b140b5bc | #30290 | - | fix(server): file changes with an empty list keep their file name | n/a: server only |
| 9e19b7f7e1 | #36526 | - | feat(server): resume stopped provider threads natively | n/a: server only |
| 0fee26d5bf | #36584 | - | fix(mobile): launch terminal commands after the measured resize | n/a: mobile only |
| 5ba3a84db4 | #36635 | - | fix(server): a locked database no longer leaves a thread stuck in "starting" | n/a: server only |
| 76748e942b | #36754 | - | test(web): wait for Settings focus before testing the theme editor's Escape | n/a: test |
| 1e9f93a48e | #28708 | - | fix(mobile): stop showing "cannot control this task" while permissions load or after a network blip | n/a: mobile only |
| 554c89320f | #29850 | - | fix(mobile): long pull request searches on iOS no longer fail the list | n/a: mobile only |
| 48afc47e77 | #29874 | - | fix(server): message search no longer finds rolled-back turns or cancelled queued messages | n/a: server only |
| e9fbb56922 | #36888 | - | test(web): terminal drawer test keeps its session atoms across GC | n/a: test |
| 42bfd1f377 | #34398 | - | fix(shared): stop rescanning unclosed TeX math | n/a: tests only |
| ff17cd307f | #36944 | - | fix(desktop): agent snapshots keep full detail in narrow and mini previews | n/a: desktop only |
| 7f81aa8386 | #36954 | - | test(web): pin the minute clock in the sidebar jump-hint render test | n/a: test |
| ee2cddf357 | #36974 | - | chore(web): upgrade @pierre/diffs to 1.7.0-beta.4 and drop patched find | n/a: chore |
| c62c7649f7 | #30311 | - | fix(server): keep Vietnamese words readable in scratch folder names | n/a: server only |
| 96ffe454cd | #30966 | - | fix(server): streamed replies keep updating after a line that starts with inline triple-backtick code | n/a: server only |
| bf8fd416a2 | #35598 | - | fix(server): Claude append launch text may start with two hyphens | n/a: server only |
| 16a70050f4 | #32376 | - | fix(desktop): voice input recovers after Linux audio restarts | n/a: desktop only |
| d8b80a1097 | #37041 | - | fix(server): status reports no branch while a clone has not checked out HEAD | n/a: server only |
| b1050d3449 | #36776 | - | test: remove duplicate client call-site coverage | n/a: test |
| 294a8418ce | #33061 | - | test(web): ACP project picker test waits for the popup to take focus | n/a: test |
| f36c8351d8 | #33978 | - | fix(server): an MCP pin lands at the top of the Pinned section | n/a: server only |
| 986975e9eb | #37089 | - | test(web): Settings Esc test waits for the modal's initial focus | n/a: test |
| 32c069eed1 | #33138 | - | fix(server): content search recovers after a slow first index | n/a: server only |
| 178570dcd3 | #29734 | - | fix(desktop): release cancelled Codex callback listeners during browser launch | n/a: desktop only |
| dcaedc9800 | #37165 | - | fix(server): skills linked by a SessionStart hook appear in the $ picker in the same session | n/a: server only |
| 16ff4b45ee | #37280 | - | fix(mobile): fully typed /model keeps its suggestion | n/a: mobile only |
| 295a0a7332 | #37100 | - | feat(mobile): open iOS images in a native viewer modelled on Messages | n/a: mobile only |
| ad1b136599 | #37470 | - | fix(server): a child's question no longer waits behind another coordinator's busy lock | n/a: server only |
| 1c7d945439 | #37674 | - | fix(web): typing in a file after a find match stays in the file | n/a: tests only |
| 83c520c21f | #37676 | - | fix(web): clicks beside an open file's find bar reach the code again | n/a: tests only |
| 1da6b14e92 | #37743 | - | refactor(client-runtime): share the Effect attachment upload registry with web | n/a: refactor |
| 8bbe7fdd1a | #37508 | - | fix(mobile): keep turn and connection status from shifting the composer area | n/a: mobile only |
| 991c62d0d7 | #37764 | - | fix(web): project picker rows no longer jump when the palette opens | n/a: tests only |
| fb89ce1680 | #37768 | - | feat(desktop): drag file pills into Finder on macOS | n/a: desktop only |
| 6794d5646c | #37792 | - | fix(desktop): relay tracing honors a telemetry opt-out from the login shell | n/a: desktop only |
| 75683c8f93 | #37835 | - | fix(contracts): preserve whitespace in diff file paths | n/a: tests only |
| 86a028cbd4 | #36724 | - | fix(server): agents can switch T3 Code back to the stock theme | n/a: server only |
| 6ad58a8485 | #37040 | - | feat(mobile): add the Issues tab and issue screens | n/a: mobile only |
| 49fad98aec | #37930 | - | refactor(issues): move issues between their tracker's own states | n/a: refactor |
| e10ea0c937 | #37938 | - | test(web): load the runtime graph before the relay telemetry cases time out | n/a: test |
| 218c18bc02 | #38085 | - | fix(server): a host-narrowed issue list still names every tracker | n/a: server only |
| 9830b857de | #38096 | - | feat(desktop): drag file pills into Explorer on Windows | n/a: desktop only |
| ffc5bbffb0 | #38182 | - | fix(mobile): fully pushed feature branch offers Create PR | n/a: mobile only |
| a774d7f473 | #38269 | - | fix(server): issue links on a custom GitHub Enterprise hostname resolve | n/a: server only |
| baab17bb03 | #38423 | - | fix(mobile): retrying an issue filter only reloads repositories that failed | n/a: mobile only |
| 5552f0aa74 | #38553 | - | fix(mobile): a retried document upload keeps its tile and shows progress | n/a: mobile only |
| c2a7c5cbc3 | #38724 | - | fix(server): subagents from earlier turns keep their model after loading history | n/a: server only |
| c7ce74fce6 | #38544 | - | perf(server): batch provider commits without blocking unrelated writes | n/a: server only |
| 733bc8f1d0 | #35306 | - | feat(mobile): select, cite, and comment on assistant text | n/a: mobile only |
| 685c2ebd45 | #38822 | - | test(web): /side attachments test waits for each side chat to start | n/a: test |
| 0226239a41 | #37948 | - | feat(desktop): render other environments' localhost tabs locally | n/a: desktop only |
| e58d0e9f03 | #38833 | - | test(web): /side attachments test no longer types a key at a time | n/a: test |
| 38e946455a | #38651 | - | fix(mobile): unavailable thread links are labeled in the app language | n/a: mobile only |
| 194b332055 | #38045 | - | feat(mobile): open localhost tabs on the device, with a Safari-style browser bar | n/a: mobile only |
| 80142c0cc3 | #38663 | - | fix(mobile): custom snooze date label follows the app language on Android | n/a: mobile only |
| d06eaff2f4 | #38707 | - | perf(server): batch Git status path lookups | n/a: server only |
| 7dceb76f4c | #26271 | - | fix(server): watched PRs wake the agent when they merge | n/a: server only |
| 28d96a2a49 | #38926 | - | fix(server): a PR watch the agent owns keeps its thread working until the PR merges | n/a: server only |
| 5d05902ddd | #26751 | - | feat(server): agents read, open, update, respond to, and merge PRs through MCP tools | n/a: server only |
| f7041fabc8 | #26752 | - | feat(server): agents read failing CI logs and re-run checks through MCP tools | n/a: server only |
