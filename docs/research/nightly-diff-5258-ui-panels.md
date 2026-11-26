# T3 Code Nightly: 4928 to 5258, panels, settings, files, git, connections and workflows

Range: v0.1.11-nightly.20261119.4928 .. v0.1.13-nightly.20261125.5258, 279 commits that touch `apps/web/src` and are not in the thread note's table. This note covers settings, pull requests and issues, files and the diff panel, git actions and the branch toolbar, the terminal, the built-in browser and previews, connections, workflows, scheduled tasks, usage, and the app shell. Thread, composer, sidebar and palette are in [nightly-diff-5258-ui-thread.md](nightly-diff-5258-ui-thread.md). The wire side is in [nightly-diff-5258-wire.md](nightly-diff-5258-wire.md), cited as "wire B1".

T3 paths are relative to apps/web/src unless they start with packages/, and line numbers refer to the 5258 tree. "CW" is CandyWrapper, with paths under Packages/CandyKit/Sources unless they start with App/.

The five changes a daily user sees first:

1. The Environments settings page is a map of your machines, with a Map and List switch (#39445, 7.1).
2. A new "New device signed in" warning toast tells you when someone signs in through T3 Connect (#42311, 7.4).
3. Issues can be filtered by project, and a project can list several Linear teams from several Linear accounts (#38799, #40023, #39179, 2.7 and 1.5).
4. Pull request stacks get "Auto-merge stack" and "Rebase stack" menu items, and the checks count says "N running" or "N failed" (#41809, #41714, 2.1 and 2.2).
5. File previews get a "Copy contents" button, and large files load in full without freezing (#34769, #40631, 3.1 and 3.2).

## How to read this

Notes name what T3 does at 5258. "CW: no" means a grep of Features and App/Sources for the T3 strings and type names found nothing. CW draws Office, RTF, OpenDocument, EPUB, TIFF, notebook and SQLite previews with QuickLook (`Features/Files/NativeFilePreviewView.swift:42`), so T3's custom parsers and their roughly 40 fixes in this range are `n/a`. CW has its own CSV and TSV table (`Features/Files/FilesLogic.swift:45`) and PDF view (PDFKit, `Features/Files/FileSurfaceView.swift:4`).

CW has no Workflows page: no workflows route, no Features folder, nothing in `docs/parity-checklist.md`. `Features/Git/ThreadLineageWorkflowViews.swift` draws only the lineage rows. Section 8 therefore describes a surface CW still has to decide on.

The commit table marks a row with † when I classified it from the subject and the changed-file list and did not open its diff. Rows without † have their diff or changed lines read. I opened about 30 diffs, so most small fixes carry †. No row says `not read`, but a † port starts by reading its commit. I made no `already` claims: I checked only a few names in CW, and none of them matched a full commit.

Sizes: S is under 20 minutes of agent work, M is 30 to 90 minutes, L is 2 hours or more. "Default look: yes" means the default themes draw something different, so fidelity references need recapturing from 5258. `redesign` means the surface also needs a Redesign (Experimental) variant.

## 1. Settings

### 1.1 Adding a keybinding searches the action list (M, default look: yes)

The "Command" field in the add-keybinding row is now a combobox with a search box and a result list (#28612).

- T3: components/settings/KeybindingsSettings.tsx:1283 (trigger `aria-label` "Command", label "Command" until one is picked), :1292 (search placeholder "Search", `aria-label` "Search"), :1295 (empty text "No results found."). The popup is `ComboboxPopup` with `className="w-96"`. Each row has the action name on the left and the current shortcut chips on the right (`flex min-w-0 flex-1 items-center justify-between gap-3`, chips in `flex shrink-0 flex-col items-end gap-1`).
- Condition rule in the same commit: sending a multiline message can use either shortcut because settings have no active composer prompt, so a pair that differs only in `composerEmpty` does not count as a conflict (components/settings/KeybindingsSettings.logic.ts, #28612 hunk). `composerEmpty` is also recognized when you type a `when` condition (#42986).
- CW: `Features/Settings/KeybindingsSettingsView.swift` and `KeybindingsLogic.swift` exist. I did not read how they pick the command. Touches both.
- Commits: 3d31ffcd9a #28612, 9a3ad0bec2 #42986.

### 1.2 Keybinding keys: layouts, plus, Option, reset (S, default look: small)

- A shortcut using "+" shows a plus keycap, not two empty pills (#40808, components/settings/KeybindingsSettings.tsx).
- Option plus a letter records the letter, not the macOS glyph (#39967). With a non-US layout, T3 reads the keyboard layout map to find the letter printed on the key (#24034, lib/keyboardLayout.ts, 44 lines). If the layout map is blocked, the old fallback stays.
- Shift+Esc records as a shortcut instead of cancelling the recorder (#42187).
- "Reset to default" restores the built-in shortcut that an edit replaced (#41630, components/settings/KeybindingsSettings.logic.ts).
- A held Esc in the search field does not close Settings, and modified Esc is ignored by it (#42419, #41784).
- CW: `Features/Keyboard/ActiveKeymap.swift` and the keybindings settings page. Check each rule against the recorder in `KeybindingsSettingsView.swift`.
- Commits: a8363dad7f #40808, e97e360cfc #39967, ba588ef663 #24034, 480f9f4861 #42187, 18d5eda881 #41630, 86272b11f0 #42419, d244be81ba #41784.

### 1.3 Esc and IME rules in search fields and dialogs (M as a batch, default look: no)

About 25 commits make one rule hold everywhere. Esc in a search or filter field clears it first and closes the surrounding dialog or sheet only on the next press. A held Esc repeat never closes a parent after a nested popup closed. An Escape that confirms an IME composition does nothing else. The rule now covers project icon search, ACP Registry search, provider model filter, custom model editor, text generator model search, voice model search, voice alias input, license search, theme search, theme editor colour filter and CSS editor, font family field, Environments map, Files search, Find in PDF, pull request search, diff and review comments, the file editor and the keybindings search.

- Base rule: components/AppRouteModal.tsx:79 ("Base UI's dismiss handler fires on held Esc repeats after a nested popup closes", #42224), `RightPanelSheet.tsx` for the right panel (#42262).
- ArrowUp in a menu search field moves to the last item (#42470, components/ui/menu.tsx). A click anywhere in the row around a popup's search focuses it (#33110, components/ui/combobox.tsx and menu.tsx).
- Escape closes a dialog over a recording before it cancels dictation (#41639, hooks/useDictationShortcut.ts).
- CW: unknown per view. The shared pieces to check first are `DesignSystem` `PopupHost` and the settings dialog's key handler. Port it as one change to the shared Esc handler, then spot-check each field.
- Commits: the rows marked (1.3) in the table. Read first: b2d51f35bb #42224, e62e5122ad #42262.

### 1.4 Scheduled tasks (S, default look: small)

- A task can set reasoning effort (#30253). T3 passes `allowPromptInjectedEffort={false}` to the effort picker at components/settings/ScheduledTasksSettings.tsx:1966 and groups the picker in `flex flex-wrap items-center gap-1.5`.
- A task made from Settings starts from the project's default branch (#32841).
- A click outside the task editor no longer discards the draft (#40708). The same holds for the project action editor (#40776, components/projectScriptEditor.tsx), and a failed import keeps newer project action drafts (#39312).
- Clearing a task's thread now sticks, which is the server side of wire B1 (#39639).
- CW: `Features/ScheduledTasks/ScheduledTasksSettingsView.swift` and `Features/Settings/ProjectActionEditor.swift`. I did not check whether CW sends an effort for tasks.
- Commits: 6205330563 #30253, b5481adcd8 #32841, c9e9e7d36a #40708, c198f73b37 #40776, 916fcdc364 #39312, 898c22f990 #39639.

### 1.5 Issue trackers: several Linear accounts and teams (M, default look: yes)

- A second Linear workspace or user can be connected. The row for the first account stays while any is connected (components/settings/IssueTrackerSettings.tsx:92) and shows an "Another account" block with the text "Connect a second {tracker} workspace or user." (:403) and an "Add account" button with a `PlusIcon` at `size-3.5` (:409, #39179). The new account's dialog says "For the new {tracker} account.". Each account row shows its workspace name in `truncate text-xs text-muted-foreground`. The account field is `w-full min-w-0 @min-[32rem]/settings-row:w-56`.
- A project can list issues from several Linear teams (#40023, same file, 101 lines changed). Agents can file issues in any bound team (#40299, server).
- CW: `Features/Settings/IssueTrackerSettingsView.swift`. I did not read how many accounts or teams it binds.
- Commits: 0591d32888 #39179, b568fcbaa6 #40023, b427708979 #40299.

### 1.6 Archived threads list stays fast (S, default look: no)

With thousands of archived threads, rows mount in chunks only near the visible part of the settings scroller and keep their last measured height otherwise (components/settings/ArchivedThreadsPanel.tsx, #41539). Rows keep `*:not-first:border-t *:not-first:border-border/50` (:79). CW draws archived threads in `Features/Settings/ArchiveSettingsView.swift`: check that it reuses rows.
Commit: fa2ee196b5 #41539.

### 1.7 Labs: "Skipped runs kept" (S, shown only with workflows on)

New row at components/settings/LabsSettingsPanel.tsx:239 (`WorkflowSkippedRunsRow`), search id `workflow-skipped-runs` (:250), scope environment. Description: "How many skipped runs each workflow keeps in its history. Older skipped runs are deleted; runs that did something are always kept." Control: a number field in `w-24`, min 0, max `MAX_WORKFLOW_SKIPPED_RUNS_KEPT`, no digit grouping, `aria-label` "Skipped runs kept", placeholder "Mixed" when environments differ. Setting key `workflowSkippedRunsKept`, default `DEFAULT_WORKFLOW_SKIPPED_RUNS_KEPT`. The reset button reads "Reset skipped runs kept to default". The row returns nothing unless `workflowsEnabled` is on, and it follows the workflows switch (`workflows-beta`). Enter commits interval fields (#42392, #42480). Skip it until CW has Workflows.
CW: no. Would touch `Features/Settings/BetaSettingsView.swift`.
Commits: c6162da7ec #42353, 54ba2408f4 #42392, 369b46900c #42480.

### 1.8 Small settings behavior (M as a batch)

All from subject and file list.

- Resetting a setting no longer jumps the page (#30925, components/settings/settingsLayout.tsx).
- Settings text typed before Navigation: Back is saved (#42085, AppRouteModal.tsx, 27 lines).
- Antigravity shows only the fields its chosen sign-in method uses (#40494, ProviderSettingsForm.tsx).
- Models stay in the picker after one failed provider check (#39114). Toggling visibility no longer jumps the model list (#31637).
- A new price row mapped to a model asks for its model ID (#41677), and restoring a saved mapping clears typed prices (#41775), both in components/usage/UsagePriceOverrides.tsx.
- Saving a voice key needs `providers:manage` (#41876, server, same family as wire B3).
- The project name field restores the saved name when cleared (#42622). Monograms: CJK names get one character (#42467), invalid monograms are blocked before save (#39131).
- The theme hex field keeps your text while you delete it (#29550). A too-large theme import invalidates pending imports (#40965). Long-named VS Code themes import separately (#39493).
- Labs device preferences show read-only for projects (#42884). Device host limit fields stay empty when cleared (#42500).
- Adding the last snooze option no longer reorders rows mid-edit (#33279).
- Diagnostics CPU history values are readable by screen readers (#41948).
- Runs of dots and hyphens render as typed with ligature fonts in the composer and script command field (#40028, #42352).
- CW: spread over `Features/Settings/*`. Read each commit, then port it as a one-file fix.

## 2. Pull requests and issues

### 2.1 Stack menu: auto-merge and rebase a stack (M, default look: yes)

The stack control is a menu plus a primary button. Menu items, in order, with their icons (components/pullRequest/PullRequestStackMenu.tsx):

- "Merge stack (N)" with `PullRequestGlyph.merged` (:280-283).
- "Auto-merge stack (N)" with `ClockIcon` (:293), when auto-merge can be enabled and is not armed.
- "Cancel stack auto-merge" with `XIcon` (:300), when armed and cancellable.
- "Rebase stack" with `RefreshCwIcon`.
- A hint line in `px-2 py-1 text-xs text-muted-foreground`: "Every layer being merged must be open and ready for review."

The button (`variant="default" size="xs"`, :343) reads "Auto-merge stack" with `ClockIcon` when `leadsWithAutoMerge`, else "Merge stack" with the merged glyph, both at `size-3.5`. It is `aria-disabled` and keeps the stale reason in `aria-description`. A confirmation dialog opens for `enable-auto-merge`, `merge` and `update-branch`. The server merges through GitHub's `includeStack` (#41809). Forgejo and GitCafe merges carry the expected head commit (#41773).

- CW: partly. `Features/PullRequests/PullRequestDetailView.swift:191` has a "Merge stack" button and `PullRequestStackViews.swift` the stack control. I found no auto-merge or rebase item.
- Commits: 69d8f4217f #41809, 0858096472 #41773.

### 2.2 Checks count label (S, default look: small)

The count beside the checks icon changes from "done/total checks" to one word for the worst state. `pullRequestChecksCountLabel` (components/pullRequest/pullRequestPresentation.tsx:602-629) returns, in order: "{count} failed" for failures and cancels, "{count} awaiting action", "{count} running", else nothing. It renders in `min-w-0 truncate tabular-nums`. CI approval stays in sync with running checks (#42523, pullRequestDetail.logic.ts).
CW: `Features/PullRequests/PullRequestChecksPopoverView.swift` and `PullRequestBadgeView.swift`. I did not read which label they draw. Recapture the PR header reference.
Commits: ba37a1afa1 #41714, 2514a5ce5e #42523.

### 2.3 Review drafts survive a reload (S, default look: no)

Draft review comments persist in a zustand store under the localStorage key `t3code:pull-request-review-drafts:v1` (components/pullRequest/pullRequestReviewStore.ts:100). Ids no longer come from a counter that restarts below persisted ids. An unfinished inline comment also survives a refresh that changes the diff (#42215, PullRequestCodeTab.tsx, 61 lines). CW: `Features/PullRequests/PullRequestReviewAnnotationViews.swift`. I did not read whether drafts persist. Use the client settings store if they do not.
Commits: 59fe770e01 #42090, 8b70e73371 #42215.

### 2.4 Open links in (S, default look: no)

Several buttons now follow the "Open links in" setting (components/settings/IntegrationsSettings.tsx:737): Open on GitHub in a thread's PR panel (#39856), the repository and loading-header links (#39926), the Open activity on host buttons and comment timestamps in the PR timeline (#42914, #42873), and the issue number in the Issue panel (#42824). Issue links inside HTML renders open in the issue panel (#41945). CW's Integrations page has the setting (`Features/Settings/IntegrationsSettingsView.swift`). Check that each link site in `PullRequestDetailView.swift` and `IssueDetailView.swift` uses the same router.
Commits: 0702c6fdca, a8f5237a3c, 60eed627d0, 6bb4e3d9d6, 2f7b7f03e3, 3fb76f1be8.

### 2.5 Mobile change that moved web logic

#26760 moves the PR file order into packages/client-runtime/src/diffFileOrder.ts so mobile matches web. The web diff is a 43-line removal from `diffFileTree.logic.ts` and 11 lines in `PullRequestCodeTab.tsx`. I read the stat only, so I mark it `n/a (moved shared logic)`. Open the commit before assuming no behavior change.

### 2.6 Small PR fixes (M as a batch)

All from subject and file list. The visible ones:

- A PR Summary tab keeps its scroll and comment order when you switch right-panel tabs (#42179, PullRequestSummaryTab.tsx, 62 lines).
- Arrow and page keys scroll the PR pane after a click or when it opens (#39319, PullRequestDetailPanel.tsx, 19 lines).
- Narrow PR Code toolbars stay readable (#42573, PullRequestCodeTab.tsx, 62 lines). A long commit name no longer runs under the Code tab icons (#39875). The new-commits banner spans the full header width (#42342).
- Closing the last open PR clears it from the list (#29438). Retry on the PR list refetches only the failed environments (#39536). A reopened closed PR tab keeps saved list filters (#42875).
- A resolved PR comment's toggle stays under the cursor when it opens (#42312).
- Checkout errors scope to the selected PR (#39554). The Link PR dialog blocks duplicate Enter submits and locks input (#42548).
- GitHub `:emoji:` shortcodes render (#39315, pullRequestMarkdown.logic.ts).
- Scrolling a PR description no longer moves focus to the condensed header (#39840).
- Diff selections that mix adds and deletes no longer show backwards ranges (#42863).
- Author and comment lines become headings for screen readers (#39648).
- Pull requests linked from an issue open beside it on the Issues page (#39937). Cmd/Ctrl+W closes the active tab on the Issues page (#42417). A reopened issue selection stays in the /issues URL (#42745).
- CW: all in `Features/PullRequests/*` and `Features/Issues/*`.

### 2.7 Issues list: choose projects (M, default look: yes)

A "Projects" item in the Issues filter menu opens a project picker. Hidden projects are kept in the URL search as `hideProjects` (components/issue/IssuesPage.tsx:212) and in localStorage under `t3.issues.preferences` (components/issue/issueListPreferences.ts:35).

- Menu row (components/issue/IssueListFilterPickers.tsx): `FolderGit2Icon` at `size-3.5`, label "Projects", right text `min-w-0 max-w-32 truncate text-xs text-muted-foreground` reading "All projects" (:103) or "{hidden} hidden".
- Picker: search field "Search projects" (:175), a "Show all" row with `LayersIcon`, rows with `ProjectFavicon` at `size-3.5` and the title, and "No matching projects." when the filter matches none.
- Empty state: "Every project is hidden" with a "Show all projects" button.
- Saved views carry the hidden projects (issueSavedViews.ts).
- CW: `Features/Issues/IssuesPageView.swift`, `IssueListLogic.swift` and `SavedViews.swift` have filters and saved views. I found no project filter.
- Commit: 9fde959ac0 #38799.

## 3. Files and the diff panel

### 3.1 Copy contents in file previews (S, default look: yes)

A button in the preview header reads "Copy contents" and switches to "Copied" with a `CheckIcon` (else `CopyIcon`), both at `size-3.5` (components/files/FilePreviewPanel.tsx:1654). A failed copy toasts "Could not copy file" (:1424). CW has Copy for loaded draft text only (`docs/parity-checklist.md` line 161). Touches `Features/Files/FileSurfaceView.swift` and `FilesPanelView.swift`.
Commit: 07fe456146 #34769.

### 3.2 Large files load in full (M, default look: small)

T3 no longer truncates large files in the preview. `components/files/LargeFilePreview.tsx` (125 lines, new) shows the file in a virtualized text viewer, Markdown renders in chunks (`ChunkedMarkdown.tsx`, 106 lines), and a new `fullFileText.ts` (90 lines) reads the file in pieces. While loading, a copy attempt says "The file is still loading. Try again in a moment." (LargeFilePreview.tsx:103). The server raises an asset limit (packages/contracts/src/assets.ts, 1 line). Exact 1,024-column CSV and TSV files no longer show the truncated-columns banner (#42973). Unchanged files do not reload during agent commands (#39736).
CW: I found no large-file path. `Features/Files/CodeFileView.swift` is the editor. Touches it and `App/Sources/FilesController.swift`.
Commits: fb4558d77d #40631, e242ed0e1a #42973, 391f93fc8f #39736.

### 3.3 Find and selection in source previews (M, default look: no)

Cmd/Ctrl+F opens find in read-only source previews (#42442, components/files/ReadOnlySourcePreview.tsx, 123 lines, plus `index.css`). Find scrolls to matches below wrapped lines (#39616). A file selection survives scrolling away and back (#39057, sourceSelection.ts). Drag selection in an editable file no longer breaks across virtualized windows (#39574). An IME Escape no longer blurs the file editor (#41837). CW: `Features/Files/CodeFileView.swift`. Check read-only mode.
Commits: bd3e495b5f, aa725f4bd4, bc6062805d, a0ef9d8d95, 6f8282c2c8.

### 3.4 Files tree and picker (S as a batch)

- Refresh reads only the folders on screen (#42870, components/files/FileBrowserPanel.tsx, useDirectoryEntries.ts).
- A revealed folder stays in view while restored folders load (#39470). Clicking the selected file in a folder view opens it (#41117). Clipped tree names show the full name on hover (#40308). Esc in the Files search clears it (#41616, #41815).
- The file picker highlights typed letters correctly after "İ" and keeps emoji whole (#41216, #42805, ProjectFilePicker.logic.ts).
- Chat file tooltips open beside the link (#41194, components/ui/shared-tooltip.tsx).
- A file link opens a file that two overlapping projects both list (#39142, client-runtime).
- An unsupported preview no longer calls extensionless filenames a file type (#42932). Markdown previews load relative images in timestamped and root folders (#41505). A 9.996 KB file reads "10.0 KB" (#42682, lib/formatBytes.ts).
- CW: `Features/Files/FileTreeModel.swift`, `FilesLogic.swift`.

### 3.5 PDF, image and CSV fixes (S as a batch)

PDF pages no longer turn black while the panel resizes (#39105). A PDF keeps its place when the pane resizes (#41537, pdfLayout.ts). Links inside a PDF are clickable (#40507, PdfViewer.tsx, 90 lines). Find in PDF clears on Esc (#41749). A cached image no longer flashes full size (#42276) and does not jump while its pane resizes (#42120). The preview only embeds PDFs from its own environment (#39497). CSV rows keep their height during horizontal scroll (#40381). CW uses PDFKit, which gives link clicks and layout, so only the environment check and the CSV row height can apply.

### 3.6 File icons and highlighting (S)

Pierre icons for test files, Vitest, Rolldown and more (#42493, lib/pierre-icons.ts, 79 lines). Verilog, SystemVerilog and VHDL highlight (#29261, composer-code-languages.ts). CW: `Features/Diff/FileIcons.generated.swift` is generated, so regenerate it from the new map.
Commits: 739bc7adb5, f8f4a0b057.

### 3.7 Diff panel (S)

A tool call's diff names its files relative to the workspace (#32697, toolCallDiff.ts). The Changes pane explains a diff made only of hidden test files (#42851, DiffPanel.tsx, 14 lines). Screen readers hear removed lines as removed (#40152, StyledDiffCodeView.tsx). A tracked file's patch skips the untracked listing (#40304) and per-file reads reuse the merge base (#40216): both server perf, `n/a`. CW: `Features/Diff`.

## 4. Git and the branch toolbar

### 4.1 Branch pickers and checkout errors (S as a batch)

Checkout failures caused by local changes explain themselves: git's sanitized detail shows in the toast instead of the operation and cwd prefix (#23346, components/BranchToolbar.logic.ts, 25 lines, BranchToolbarBranchSelector.tsx). A remote with slashes shows the right name (#42301). Picker branch switches no longer re-read the full local status (#40389). Branch pickers refresh after an external worktree change (#40556, WorktreeBaseBranchPicker.tsx). CW: `Features/Git/BranchPickerView.swift`, `BranchToolbarLogic.swift`.

### 4.2 Push and progress text (S)

Push on the default branch no longer commits files changed while you confirm (#41844, components/GitActionsControl.logic.ts:502 holds the "Commit & push to default ref?" dialog). Git action progress text centres with its spinner (#37215, GitActionsControl.tsx, `grid min-w-0 flex-1 items-center` at :377). CW: `Features/Git/GitActionsLogic.swift`.

### 4.3 Clone failure toast (S)

A clone failure still shows after the progress toast is dismissed (#40951, components/ProjectCloneToastCoordinator.tsx, 57 lines changed; the fallback text is "An error occurred.", :67). CW: the project add flow in `App/Sources`.

## 5. Terminal

### 5.1 The terminal button reopens the drawer (S)

After the last terminal closes, the terminal button opens the drawer again with a new terminal (#39260, state/terminalUiStateStore.ts:342, `setThreadTerminalOpen`). CW: `Features/Terminal/TerminalDrawerView.swift`.

### 5.2 Copy and Ctrl+B with a terminal focused (S)

Terminal copy shortcuts type nothing when no text is selected (#41702, terminal/ghostty/surface.ts). Ctrl+B reaches a focused terminal again, because the sidebar toggle checks `terminalFocus` in the keybinding context (#34588, components/AppSidebarLayout.tsx:260 and keybindings.ts:44). CW: `Features/Terminal/TerminalSurfaceView.swift`. SwiftTerm draws Powerline cells itself, so #24888 is `n/a`.

### 5.3 Terminal labels follow the language (S, probably n/a)

Terminal labels update when the language changes (#42872, terminal/ghostty/surface.ts, 80 lines). I did not check whether CW has a language setting. If it does not, `n/a`.

## 6. Browser and previews

### 6.1 Browser history keeps every tab's visits (M, default look: no)

History lives in IndexedDB under `t3code:browser-history:v1` (components/browser/browserHistoryStore.ts:179, :319), migrates once from the old localStorage copy, merges in visits other tabs add, and tells other tabs through a `BroadcastChannel` of the same name (:496). With no storage it stays in memory. New registrations for empty projects are kept and projects that lost their history are dropped. CW: `App/Sources/BrowserController.swift` and `Features/Browser/BrowserPanelView.swift`. I did not read how CW stores history. Compare before porting the merge logic.
Commit: ffb42a0b77 #40543.

### 6.2 Viewport and capture (S as a batch)

Hidden preview tabs larger than the window capture whole (#26965), the same for desktop (#36286, browser/browserViewportLayout.ts). Enter saves the default viewport size (#42480). A floating device preview keeps its stream across thread switches (#40240). Agent recordings keep refining the frame while the page is idle (#42445). Cmd+T opens the new-tab menu from a focused browser page (#39769). The element context preview no longer ends in a split surrogate (#42585): `n/a`, Swift Characters. CW: `Features/Browser/BrowserViewport.swift`, `BrowserMiniPlayerView.swift`.

### 6.3 Streamed tabs show native select menus (S)

A streamed browser tab opens `<select>` menus: `ServerBrowserSurface.tsx` keeps a `selectMenu` state of type `PreviewStreamSelectMenu` (components/browser/ServerBrowserSurface.tsx:197, 59 lines changed, #31561). CW: `Features/Browser/ServerBrowserView.swift`. It needs the wire field the preview stream sends, so check the wire note first.

## 7. Connections and T3 Connect

### 7.1 The Environments page is a map (L, default look: yes, redesign)

Settings, Environments shows a map of your machines on md and wider screens. A Map and List switch sits in the page title (components/settings/ConnectionsSettings.tsx:1840 `ToggleGroup` with `aria-label` "Show environments as", `Toggle value="map"` "Map" at :1847, `Toggle value="list"` "List" at :1850). Below md the list shows. The choice is not stored: map is the default (`pickedEnvironmentsView ?? "map"`). Files: EnvironmentsMap.tsx (2,291 lines), EnvironmentsMapDetails.tsx (881), environmentsMap.logic.ts (1,979).

Canvas and toolbar (components/settings/EnvironmentsMap.tsx):

- Canvas height clamps to 180 to 840 px (:147). The canvas is `relative min-h-45 cursor-grab touch-none overflow-clip bg-background/50 select-none` (:1010) and shows `cursor-grabbing` while dragging. The viewport glides with `transition-transform duration-200 ease-out` and respects reduced motion (:1037). The selection rectangle is `rounded-sm border border-primary bg-primary/10` (:1051).
- Toolbar row: `flex flex-wrap items-center gap-x-3 gap-y-1.5 rounded-t-xl border-b border-border/60 bg-background/50 px-3 py-1.5` (:885) with a `w-48` search field, placeholder "Find a machine" (:896), `aria-label` "Find a machine on the map". Status text beside it: "No machine by that name" or "{count} match(es)" (:916-917). Search centres a machine at scale 0.85 or larger (:157).
- Right side of the toolbar: "{count} selected" with a "Clear" button, "Link several…" (:941), and a help popover `aria-label` "How to use the map" with `list-disc space-y-1 pl-4 text-xs text-muted-foreground` and the lines "Select a machine to manage it.", "Drag a plus onto a machine to link them.", "A link reaches one machine and stops there." (:985-992). "Shift-click or Shift-drag to select several" is a tooltip (:881).
- Footer row `flex items-center justify-between gap-3 bg-background/50 px-3 py-1` (:1056) holds a zoom group `flex shrink-0 items-center gap-1 rounded-lg border border-border/60 bg-popover/90 p-0.5 shadow-xs/5` with "Zoom out", "Zoom in" and "Fit the map to view" icon buttons (:1062-1078), and the legend.
- Legend (:1091): list `aria-label` "How to read the lines", `text-2xs text-muted-foreground`, items "In use", "Standby", "Offline", "Link" (a triangle) and, only when some link goes both ways, "Two-way".
- Line styles (:144-175, :190-206): access strength maps to stroke widths 1.25, 1.75, 2.25, 2.75, 3.5 and opacities 0.4, 0.5, 0.62, 0.76, 0.9. Link health adds a dash: expired `1 5`, failing `8 3 1 3`, unreachable `5 4`. Machine borders: expired `border-dotted border-destructive/70`, failing `border-destructive/70`, unreachable `border-dashed border-foreground/35`, else `border-border`, or `border-warning/70` when the link expires within days. Route states: in-use `text-success` width 1.75, standby `text-muted-foreground/60`, trying `text-warning` dash `1 4`, down and idle dashed `4 4`, refused `text-destructive/80`, offered dotted. An opened stack fades in with `transition-opacity duration-200 ease-out starting:opacity-0` (:160).
- Keys: arrow keys rove between machines (:150).

Texts (same file): connection states "Connected", "Connecting…", "Waiting for approval", "Reconnecting…", "Client not supported", "Connection failed", "Offline", "Not connected", "Off", "Sign-in refused" (:1140-1166). Link states "Loading links…", "Links could not be loaded", "Linked environments is off", "Links not readable from here", "{count} links out" (:1180-1188). Relay states "Relay online", "Relay offline", "Checking relay status…", "Relay status unavailable" (:1200-1206). Drop actions "Link to {target}", "Renew link to {target}", "Link to {target} with a pairing code", "Link to {count} machines", "Cannot link to this" (:1301-1322). Group labels "Offline", "Switched off", "Need an update", "Not added" (:1328-1336). A code-only drop shows a notice with "Link one with a code…" and a "Dismiss" button (:1265-1287).

Details panel (EnvironmentsMapDetails.tsx): link status "Reachable", "Expires in {days} days", "Expired", "Not answering", "Failing" (:57-65). Rows "Access", "Status", "Expires", "Addresses", "Linked", "Last reached" (:836-874). Buttons "Link back…", "Forget" and "Forgetting…" (:818-830), "Reconnect", "Link", "Add environment", "Try again". Group cards: "{count} environments", "No links", "{reachable} reachable" or "None reachable", "Show on map" or "Collapse", a "Filter by name" field and "{shown} of {count}" (:427-470). Messages: "Two links, one each way." (:186), "Not connected, so its links are not shown.", "To link from {label}, turn on Linked environments in its Labs settings.", "This app may not read the links {label} holds.", "Each line from here is a saved route to an environment.", "Add {label} to this app to connect to it.", "Known only through a link".

Behavior: Esc on the map clears the selection without closing Settings (#43017). Zoom controls are centred (#41081). Picking a machine the map knows an address for opens `AddEnvironmentDialog` with that address prefilled (`initialHost`, ConnectionsSettings.tsx diff for #39445).
Gate: the map only draws links it can read, so it needs the peer link list calls (wire A6 family). Without them, draw only saved machines.
CW: no. `Features/Settings/ConnectionsSettingsView.swift` and `LinkedEnvironmentsViews.swift` show the list. It needs a custom-drawn canvas view, a layout engine (port `environmentsMap.logic.ts`, `buildFleetGraph`) and a details panel. I read the toolbar, legend, styles and strings, not the layout engine.
Commits: ccabed086a #39445, 605980d397 #43017, 65d2b4f081 #41081.

### 7.2 Link several environments at once (M, default look: yes, redesign)

A dialog links many machines from one source. Title "Link several environments" or "Link several machines from {source}" (components/settings/LinkSeveralEnvironments.tsx:215-216). The popup is `DialogPopup className="max-w-md"` (:211). The list is `max-h-72 divide-y overflow-y-auto rounded-lg border` (:295), rows `flex cursor-pointer items-center gap-2.5 px-3 py-2 text-sm` with a checkbox and an icon at `size-4 text-muted-foreground`. Header: "Select all" and "Select none" (:263-264). Row results: "Linking…", "Linked both ways", "Linked one way", "Linked", "Could not link back: {reason}". A footer checkbox reads "Also link each machine back to {source}" with the sub-text "Agents there can then work on {source} too." (:401-404). Buttons: "Cancel" turns into "Done" after a run, and "Link {count} machine(s)" turns into "Linking…". Summary: "Linked {count} machine(s)." (:376).
CW: no. `App/Sources/PeerLinkDialog.swift` links one machine.
Commit: 8e8ff9b243 #39426.

### 7.3 Link a machine through another environment (M, default look: small)

You can link machine B through machine A that already links to it, so no pairing code is needed. components/settings/LinkedEnvironmentsSettings.tsx (152 lines changed) offers the address list from `linkableMachines` and `ANOTHER_ADDRESS` (client-runtime `link-request`), and `state/peerLinks.ts` (37 lines) and `environmentsMap.logic.ts` carry the offer. The map's drag-a-plus gesture uses the same call. Gate: wire A6. CW: `Features/Settings/LinkedEnvironmentsViews.swift`, `T3Protocol/Domain/PeerLink.swift`.
Commit: 6f644f6e91 #40036.

### 7.4 "New device signed in" toast (S, default look: new toast)

A warning toast with no timeout (`timeout: 0`) appears when a T3 Connect device the client has not announced signs in (components/ConnectDeviceApprovalCoordinator.tsx:113-152). Title "New device signed in to {environmentLabel}". Body "{device} connected through T3 Connect. Not you? Review it." for one device and "{count} devices connected through T3 Connect. Not you? Review them." for several. The action button "Review" opens `/settings/access` with `machine={environmentId}` and marks the devices seen. The copy button is hidden (`hideCopyButton: true`). Closing the toast also marks them seen. One toast per environment updates in place, and a dismissed toast makes the next unseen device a new one. Storage: localStorage key `t3code:connect-devices-seen-through`.
CW: partly. `Features/Settings/ConnectionsHostViews.swift` lists devices and `T3Protocol/Wire/AuthHTTP.swift` decodes them. I found no toast. Touches `ConnectionsHostViews.swift` and the toast code in `App/Sources` (path not checked).
Commit: ece5f21b17 #42311.

### 7.5 Connection fixes (S as a batch)

SSH connection checks stay pending until they finish (#39328). A failed port-forward locality probe retries (#41353). A reopened pairing link dialog stays open on completion (#39579, AuthorizedClientsSettings.tsx, 33 lines). Remove is not offered on a route the environment cannot lose (#41845). A linked thread read restarts on Try again (#41020), and a pairing tab closing keeps the conversation (#41025). Saves, account switches and registrations report their own outcome (#38911, managedAuth.tsx). Server side only: unlinking ends the other machine's session (#41005), link codes and guest links need the access they hand out (#41742), remote logins and webhook tokens stay with their own host (#41756). CW: `Features/Settings/ConnectionsHostViews.swift`, `App/Sources/PeerLinkDialog.swift`.

## 8. Workflows

Workflows sit behind the Labs switch `workflowsEnabled` (`workflows-beta`). The route is `/_chat/workflows` (routes/_chat.workflows.tsx:9) and the page is components/workflows/WorkflowsPage.tsx. CW has no workflows surface, so 8.1 comes first.

### 8.1 The Workflows page (L, new surface for CW, redesign)

Files at 5258: WorkflowsPage, WorkflowRunsView (run list with tabs), WorkflowRunFeed (the run's beats, about 2,000 lines), WorkflowDefinitionEditor, WorkflowPane and WorkflowThreadPane (a run's thread opens in the right panel), WorkflowReferences, WorkflowRunsAbout. The user decides whether CW needs workflows at all, because this is a whole feature. If yes, read WorkflowRunsView and WorkflowRunFeed first and cite each element then. CW: no.

### 8.2 Pools cap what runs at once (S)

A run waiting for a pool slot draws a `HourglassIcon` at `size-3.5 text-muted-foreground` and the note "queued · {length}" (components/workflows/WorkflowRunFeed.tsx:1635-1646). The server queues. Commit: 462596a0f7 #42518.

### 8.3 Questions take choices, reasons, links, and a withdraw state (M)

- A question's choices can carry a description, shown in `max-w-60 text-xs text-muted-foreground` beside the choice (WorkflowRunFeed.tsx:1996-1997).
- An answer reads "You said {choice}" or "{who} said {choice}", so the answerer is kept (#42515).
- A question can be withdrawn without cancelling its run (#42506): "withdrawn · {length}" (:1554), "Withdrawn by {by}." or "Withdrawn by {by}: {reason}" (:1547-1548), and in the run's summary line "withdrawn by {by}" or "nobody answered" (:1305, :1557).
- Gate: the server's workflow question fields. I did not check the wire note for them.
- Commits: 7be3a767cc #42515, 3b5033a28c #42506.

### 8.4 Question kinds and the Needs you filter (M)

Runs carry tags and questions have kinds. On the "Needs you" tab a "Kind of question" select appears when any kind exists (components/workflows/WorkflowRunsView.tsx:340-370): size `sm`, value "All kinds" or "{kind} {count}", items show the name and a right-aligned `text-muted-foreground tabular-nums` count. With "All kinds" picked, a line `px-1 text-xs text-muted-foreground` lists "{kind} {count} · ..." joined by " · ". Questions with no kind are "Other". Empty text with a kind picked: "No questions of this kind wait on you." (:392). The pick persists under the localStorage key `t3code:workflows:question-kind` (:47, :109), with `*` meaning all kinds. The pick holds the tab on Needs you even after its last question is answered. An opened run stays listed whatever it asks.
Commit: 5ac27b4007 #42008.

### 8.5 A run can declare its subject (S)

A run names the thread, PR or issue it is about. That item's own view gets a "Workflow runs" block: an `h3` in `text-xs font-medium text-muted-foreground` (components/workflows/WorkflowRunsAbout.tsx:32) over rows `flex min-w-0 items-center gap-1.5 rounded-md px-1.5 py-1 text-xs hover:bg-accent/50 focus-visible:ring-2 focus-visible:ring-ring/70 focus-visible:ring-inset`, title in `min-w-0 flex-1 truncate text-foreground`. The same list shows on the Issue and PR Summary tabs (IssueDetailPanel.tsx, PullRequestSummaryTab.tsx). CW: no. Commit: 8987ba39d4 #42517.

### 8.6 Small workflow fixes (S)

Workflow steps on a linked environment open their thread (#41614, useWorkflowThreadOpen.ts). Bad pane links no longer pick the first tab or crash (#42791, workflowPane.logic.ts). Skipped runs stop keeping their webhook payloads (#42353, server).

## 9. Usage

### 9.1 Pooled limits refill line (S)

The pooled-limit card lists rows "Plan", "Signed in" or "Via", "Left" ({remaining}%), "Resets", "Even pace" ({timeLeft}% left by now) and "Restores" ("+{percent}% of pool") (components/usage/UsageLimitsPooled.tsx:187-214). The refill line is one translated sentence (#42502) and shows when the pool lands again (#42499), skipping elapsed resets (#42037). Refill stripes all render the same width (#30407). CW: `Features/Usage/UsageLimitsView.swift`.
Commits: 617d6ab628, 7380740efe, 139af501b6, 18d1c4db96.

### 9.2 Usage text and shortcut (S)

Usage says "1 session", not "1 sessions" (#42837, components/usage/UsagePage.tsx:705). Pressing the Usage shortcut again closes Usage (#30459, AppRouteModal.tsx, UsagePage.tsx). A stale Usage Limits scrollbar is fixed (#40816): `n/a`, web scroll area. CW: `Features/Usage/UsagePageView.swift`.

## 10. App shell and dialogs

### 10.1 Reopen closed view (M, default look: no)

The reopen shortcut (components/ReopenClosedViewShortcut.tsx, 56 lines added in #40516) preserves newer navigation when it reopens a closed view. A reopened closed pull request tab keeps its saved list filters (#42875). The shortcut forwards from a focused preview page: `PREVIEW_FORWARDED_COMMANDS` lists `workspace.focusNext`, `workspace.focusPrevious`, `sidebar.toggle`, `rightPanel.toggle`, `rightPanel.toggleMaximized`, `rightPanel.new`, `rightPanel.close`, `preview.focusUrl`, `preview.zoomIn`, `preview.zoomOut`, `preview.resetZoom`, `preview.find` (:60-72). A failure toasts "Could not reopen view" (:215).
CW: partly. `T3Store/RightPanelState.swift`, `App/Sources/FilesController.swift:653` and `BrowserController.swift` hold the reopen stack. Check the forwarded list.
Commits: c6ca01b373 #40516, 45c011e218 #42875, 21a96989b0 #42745, 966e422c9f #39769.

### 10.2 Held shortcuts do not flicker (S)

Held overlay and Usage shortcuts no longer flicker (#42757, shortcuts/commandPaletteCommands.ts). The base behavior is in 1.3.

### 10.3 New thread from a grouped repository (S)

A new thread from a grouped repository starts in its root checkout (#37191, hooks/useHandleNewThread.ts, 18 lines, sidebarProjectGrouping.ts). CW: the sidebar grouping in `Features/Sidebar` and the new-thread path in `App/Sources`.

### 10.4 Add-surface menu hides when empty (S)

The right panel's add-surface menu is hidden when no surface is available (#42722, components/RightPanelTabs.tsx, 75 lines). Opening it from the forwarded shortcut does not focus the trigger, because ChatView's window-focus handler would refocus the composer and close the menu. CW: `T3Store/RightPanelState.swift`.

### 10.5 Zoom and find keys in the right panel (S)

Zoom shortcuts zoom the app from the PR, Diff and Files panes (#39207, shortcuts/chatRouteCommands.ts:131: "Unclaimed, zoom keys reach the desktop menu accelerators or the browser's own zoom"). Cmd/Ctrl+F opens the browser find bar while a pull request is maximized (#41852). CW: key routing in `App/Sources`.

### 10.6 Small shell fixes (S as a batch)

Dropped thread attachment names no longer break on long titles (#42727). Downscaled image attachments keep Display P3 colors (#40501). A failed checkpoint capture keeps "Edit from here" (#40745). Background announcements stay quiet for held or stopped runs (#40585). Update checks name the track mismatch (#38506, #39302): Electron updater, `n/a`. CW: `App/Sources`.

## 11. Commit table

Status values: `port` names the note above. `n/a` gives the reason in three words. † marks a row classified from the subject and file list without opening its diff. The Area column is my grouping.

| Commit | PR | Subject | Area | Status |
|---|---|---|---|---|
| 000ba180be | #41025 | fix(web): keep the conversation when a pairing tab closes | connections | port (7.5) † |
| 009ae578d0 | #42727 | fix(web): long thread titles no longer break dropped thread attachment names | shell | n/a (CW has no dropped thread attachment; Swift `prefix` never splits a Character) |
| 01794015f8 | #40998 | fix(web): prioritize visible saved notebook outputs | files | n/a (QuickLook previews, diff read 2026-11-25) |
| 02c5270a11 | #39328 | fix(web): keep SSH connection checks pending until they finish | connections | port (7.5) † |
| 036751b6f5 | #41856 | fix(web): Esc in project icon search clears it without closing the dialog | settings | ported cb5edfe1 |
| 0591d32888 | #39179 | feat(issues): connect more than one Linear account | issues | ported 31648718 |
| 0702c6fdca | #39856 | fix(web): Open on GitHub in a thread's PR panel honors 'Open links in' | pull requests | ported 7835705c |
| 072611f65f | #42682 | fix(web): a 9.996 KB file reads "10.0 KB", not "10.00 KB" | files | ported 62cbede9 |
| 07fe456146 | #34769 | feat(web): copy button for file previews | files | ported 3b118df1 |
| 0854259384 | #40308 | fix(web): clipped Files tree names show the full name on hover | files | ported 9ee37242 |
| 0858096472 | #41773 | fix: Forgejo and GitCafe merges carry the expected head commit | pull requests | ported d727914e (banner, Load new commits and the head pin from #41761) |
| 09385a33ce | #42974 | fix(shared): usage page says "record was skipped" for one malformed record | usage | n/a (server string) † |
| 0afc7a1439 | #40028 | fix(web): typed runs of dots no longer vanish in the composer with ligature fonts | settings | port (1.8) † |
| 0c13b2b8fc | #42158 | fix(web): Esc in ACP Registry search clears it without closing Add provider | settings | ported cb5edfe1 |
| 0f55a0dc37 | #42900 | fix(web): empty files and folders in archive previews show 0 bytes instead of 1 KB | files | n/a (QuickLook previews) † |
| 0fd4822887 | #40216 | fix(server): per-file diff reads reuse the preview's merge base | git | n/a (server perf) † |
| 0fd87d3c2e | #41616 | fix(web): Esc in the Files search clears it without closing the sheet | files | ported 9ee37242 |
| 1368854828 | #36286 | fix(desktop): capture the whole oversized preview viewport | browser | n/a (HostedBrowserWebview), diff read 2026-11-25 |
| 139af501b6 | #42037 | fix(usage): skip elapsed resets in pooled refill summaries | usage | ported 8f1d707d |
| 1458a42419 | #40424 | fix(server): transcript cleanup failures tell the user why | settings | port (1.8) † |
| 14c697c4f1 | #41514 | fix(web): RTF previews read text in an ANSI font as code page 1252 under any document code page | files | n/a (QuickLook previews) † |
| 18d1c4db96 | #30407 | fix(web): usage limit refill stripes all render the same width | usage | ported 8f1d707d |
| 18d5eda881 | #41630 | fix(web): Reset to default restores the built-in shortcut an edit replaced | settings | ported d476c29f |
| 192ef9b7b2 | #41196 | fix(web): preserve alpha channel when previewing WhiteIsZero TIFF images | files | n/a (QuickLook previews) † |
| 1a11aed1f8 | #41614 | fix(web): workflow steps on a linked environment open their thread | workflows | port (8.6) † |
| 1a42ba1b5f | #39114 | fix(server,web): models stay in the picker after one failed provider check | settings | port (1.8) † |
| 1a51984153 | #32697 | fix(web): a tool call's diff names its files relative to the workspace | files | ported 2c65d585 |
| 20a3bed880 | #42617 | fix(web): long Workflows links no longer end in a broken character | workflows | port (8.6) † |
| 20b8a9e695 | #39497 | fix(web): the preview only embeds PDFs from its own environment | files | n/a (CW never embeds preview PDFs; the check is in the web PiP), diff read 2026-11-25 |
| 210996207d | #26760 | feat(mobile): pull request files follow the same review order as web | pull requests | ported da18c3b2 |
| 21a96989b0 | #42745 | fix(web): include reopened issue selection in the /issues URL | shell | ported 05c24604 |
| 21d7feaff7 | #29550 | fix(web): theme hex field keeps your text while you delete it | settings | port (1.8) † |
| 227ac64b74 | #40501 | fix(web): downscaled image attachments keep Display P3 colors | shell | already (ImageIO thumbnails keep the source color space and CGImageDestination embeds it, ComposerAttachments.swift:417-466; checked with a P3 PNG) |
| 22f006c8d7 | #39207 | fix(web): zoom shortcuts zoom the app from the PR, Diff and Files panes | shell | already (previewFocus covers only the browser view, so from PR, Diff and Files the View menu zooms the app), diff read 2026-11-25 |
| 23e6e913d5 | #40509 | fix(web): ODT previews no longer print an index's title twice or its entry separators | files | n/a (QuickLook previews) † |
| 2514a5ce5e | #42523 | fix(pr): keep CI approval in sync with running checks | pull requests | ported fc8c0c41 (the refresh flag; the checks merge is n/a, CW rereads the whole detail) |
| 2526691ea5 | #39157 | fix(mobile): cancelling a model download keeps the current transcription model | other | n/a (mobile only) † |
| 25440f5bd5 | #41008 | fix(web): navigate Excel sheets from the focused tab | files | n/a (QuickLook previews) † |
| 26c21a86cf | #42149 | fix(web): ODS previews hide values a merge covers | files | n/a (QuickLook previews) † |
| 26f4c7550e | #42076 | fix(web): Esc in provider model filter clears it without closing Settings | settings | ported cb5edfe1 |
| 2713570406 | #38506 | fix(desktop): update checks say why a build with a different saved track offers nothing | shell | n/a (Electron updater) † |
| 28706aceb6 | #41005 | fix(server): unlinking an environment ends its session on the other machine | connections | n/a (server side, wire) † |
| 28bcb73736 | #40240 | fix(web): floating device preview keeps its stream across thread switches | browser | ported 5c75e9ac |
| 2a411317d9 | #39105 | fix(web): PDF pages no longer turn black while the panel is resized | files | n/a (PDFKit draws the pages) |
| 2c33cbdf02 | #39643 | fix(web): strip terminal colors from saved notebook output | files | n/a (QuickLook previews) † |
| 2c95b69f25 | #42627 | fix: screenshots after a caption render full size instead of as chips | files | n/a here: a Markdown pipeline fix, not a QuickLook preview; belongs to the thread note |
| 2e6b05011f | #24888 | fix(web): terminal Powerline caps and slants fill their cells | terminal | n/a (SwiftTerm draws it) † |
| 2f7b7f03e3 | #42824 | fix(web): issue number in the Issue panel follows 'Open links in' | issues | ported 7835705c |
| 3336504f31 | #42445 | fix(preview): agent recordings keep refining the frame while the page is idle | browser | n/a (recording compositor, CW records nothing in the client), diff read 2026-11-25 |
| 3373a78606 | #42872 | fix(web): update terminal labels when the language changes | terminal | n/a (CW has no translations: General settings says other languages are not available), diff stat read 2026-11-25 |
| 338352dee2 | #39833 | fix(web): spreadsheet scrollbars are visible in dark mode | files | n/a (QuickLook previews) † |
| 356dff3352 | #40783 | fix(web): RTF previews respect hidden character formatting | files | n/a (QuickLook previews) † |
| 3571f28cca | #40816 | fix(web): Usage Limits no longer shows a stale scrollbar | usage | n/a (web scrollbar) † |
| 369b46900c | #42480 | fix(web): Enter saves the default viewport size and skipped runs kept | settings | port (1.8) † |
| 36d6333885 | #42573 | fix(web): keep narrow PR Code toolbars readable | pull requests | ported 4b07f98d (short commit id below 36rem, the hidden-tests link from 42rem, the only-hidden-tests state), diff read 2026-11-25 |
| 391f93fc8f | #39736 | fix(web): stop reloading unchanged file previews during agent commands | files | holds for reloads (CW reads an open file again only on Force Reload); left: renew the HTML page grant two minutes before its hour ends (S) |
| 3b5033a28c | #42506 | feat(server): withdraw a waiting workflow question without cancelling its run | workflows | port (8.3) |
| 3b829b6aa6 | #42130 | fix(web): Esc in the text generator model search clears it without closing the dialog | settings | ported cb5edfe1 |
| 3d31ffcd9a | #28612 | feat(web): search actions when adding keybindings | settings | ported 5dce46e3 |
| 3d4fd8346e | #42563 | fix(web): long Pull Requests author and label filters no longer end in a broken character | other | n/a (Swift Characters) † |
| 3d54dc96f9 | #33110 | fix(web): focus popup search from anywhere in its row | shell | ported d39a9a88 (menus with a search field and the branch picker; the other hand-built comboboxes in Sidebar, Settings and Composer still focus only on the field), diff read 2026-11-25 |
| 3dd4f14280 | #41932 | fix(web): IME keys no longer cancel or send a pull request review reply | pull requests | already (AppKit gives marked text to the input method before `doCommandBy`, PullRequestReviewAnnotationViews.swift:237, and no page monitor takes Esc) |
| 3ea709e8bd | #39470 | fix(web): keep revealed folder in view while restored folders load | files | n/a (CW restores no expanded folders; a reveal scrolls once its ancestors load, FilesController.swift:342-376) |
| 3fb76f1be8 | #41945 | fix(web): issue links in HTML renders open in the issue panel | issues | ported 7835705c (chat and HTML render issue links open the issue panel) |
| 4065801a00 | #30459 | fix(web): pressing the Usage shortcut again closes Usage | usage | ported e9ebf28f |
| 4113f8fee5 | #39131 | fix(web): block invalid project monograms before save | settings | port (1.8) † |
| 426dac0050 | #41948 | fix(web): expose diagnostics CPU history values to screen readers | settings | port (1.8) † |
| 43d9d67140 | #32768 | fix(web): an IME Escape no longer clears a typed font family | settings | ported cb5edfe1 (an IME Esc passes to the input method) |
| 43e0b37382 | #42179 | fix(web): PR Summary tab keeps its scroll and comment order when you switch right-panel tabs | pull requests | ported f8432554 |
| 4568a1b741 | #42932 | fix(web): unsupported file preview no longer calls extensionless filenames a file type | files | n/a (CW previews unsupported files with QuickLook; its fallback names no file type) |
| 457a52eb0a | #42312 | fix(web): opening a resolved PR comment keeps its toggle under the cursor | pull requests | already (CW's opened resolved card puts nothing before the toggle; it has no Resolve button there), diff read 2026-11-25 |
| 45c011e218 | #42875 | fix(web): reopening a closed pull request tab keeps saved list filters | shell | ported 05c24604 |
| 462596a0f7 | #42518 | feat(workflows): named pools cap how much runs at once, with queueing | workflows | port (8.2) |
| 46eb376dda | #41677 | fix(web): a new price row mapped to a model asks for its model ID | settings | port (1.8) † |
| 475ae52ac2 | #39067 | fix(web): a corrected telemetry URL can be tested while an earlier check runs | settings | n/a (telemetry URL check) † |
| 480f9f4861 | #42187 | fix(web): shortcut recorder takes Shift+Esc instead of cancelling | settings | ported d476c29f |
| 4b697be849 | #39331 | fix(web): keep deleted ACP sessions out of pending listings | settings | port (1.8) † |
| 4ce9f8c1b8 | #41647 | fix(web): Esc in the license search closes it without closing Settings | settings | ported cb5edfe1 (CW clears the text; T3 also closes the search box) |
| 4e6b1fa771 | #42585 | fix(web): element context preview no longer ends in a split surrogate | browser | n/a (Swift Characters never split a surrogate) |
| 511447a9f2 | #40207 | feat(server): add a TanStack Source forge and issue tracker behind T3CODE_TANSTACK_SOURCE | other | n/a (server only, wire) † |
| 515cab980a | #42352 | fix(web): script command field shows both hyphens with ligature fonts | settings | port (1.8) † |
| 524c757f82 | #39846 | fix(web): RTF previews read Mac Roman documents | files | n/a (QuickLook previews) † |
| 54ba2408f4 | #42392 | fix(web): Enter commits Background Activity interval values | settings | port (1.8) † |
| 550c26635b | #41610 | fix(web): SSH projects open in a new VS Code window | other | n/a (server only, wire) † |
| 5935157711 | #40541 | fix(web): keep secret check replies tied to their own attempt | settings | port (1.8) † |
| 59651c1761 | #39536 | fix(web): Retry on the Pull Requests list only refetches the environments that failed | pull requests | ported 6243ff00 |
| 597c8de32b | #26965 | fix(web): hidden preview tabs larger than the window capture whole | browser | n/a (HostedBrowserWebview, CW streams every tab), diff read 2026-11-25 |
| 59fe770e01 | #42090 | fix(web): pull request review drafts survive a reload | pull requests | ported 9e30cb36 |
| 5ac27b4007 | #42008 | feat(workflows): questions have kinds and runs have tags, and Needs you filters by kind | workflows | port (8.4) |
| 5bd0616f05 | #41020 | fix: restart linked thread reads when trying again | connections | port (7.5) † |
| 5bf6b122b5 | #41838 | fix(web): a long pull request search no longer ends in a broken character | other | n/a (Swift Characters) † |
| 605980d397 | #43017 | fix(web): pressing Escape on the Environments map clears selection without closing Settings | connections | left (with the map) |
| 60eed627d0 | #42914 | fix(web): PR timeline "Open activity on host" buttons honor 'Open links in' | pull requests | ported 7835705c |
| 617d6ab628 | #42502 | fix(web): translate the pooled limit refill line as one sentence | usage | ported 8f1d707d |
| 6205330563 | #30253 | fix(web): allow setting reasoning effort for scheduled tasks | scheduled tasks | ported 7d3c372e |
| 620cf4770d | #40856 | fix(web): browser page translation no longer crashes the app when a turn updates | other | n/a (translation strings) † |
| 622f96785a | #42500 | fix(web): device host limit fields stay empty when cleared | usage | n/a (CW has no EAS or Simlock host editor) |
| 6233f5d114 | #41639 | fix(web): Escape closes a dialog over a recording before canceling dictation | shell | n/a (CW has no dictation) |
| 6357d17a49 | #31637 | fix(web): toggling a model's visibility no longer jumps the model list | settings | port (1.8) † |
| 637cd28599 | #41845 | fix(client-runtime): Remove is no longer offered on a route the environment cannot lose | connections | port (7.5) † |
| 65b2e6dae6 | #41122 | fix(web): stop telemetry refresh spinning after data arrives | settings | n/a (telemetry refresh) † |
| 65cd644623 | #41301 | fix(web): archive folders with leading or repeated slashes show their names | files | n/a (QuickLook previews) † |
| 65d2b4f081 | #41081 | fix(web): center the Connections map zoom controls | connections | left (with the map) |
| 66a4d99d1d | #37215 | fix(web): git action progress text centers with its spinner | git | already (ThreadDetailsCardView centres the label and time in the 32pt row) |
| 670092dcf6 | #40152 | fix(web): screen readers can tell removed lines from added ones in diffs | files | ported 4a7b928b (CW line rows had no VoiceOver text at all) |
| 6972026121 | #40951 | fix(web): show clone failure after progress is dismissed | git | ported 05d384e0 |
| 69d8f4217f | #41809 | feat: auto-merge a stack through GitHub's includeStack | pull requests | ported c0e8fcea |
| 6bb4e3d9d6 | #42873 | fix(web): comment timestamps follow 'Open links in' | connections | ported 7835705c |
| 6c0621f78a | #42301 | fix(web): branch picker shows the right name for remotes containing slashes | git | ported 32cc3467 |
| 6f49071a3d | #40745 | fix: a failed checkpoint capture keeps Edit from here for conversation rewind | shell | left: CW rewinds only to `ready` checkpoints (ThreadPromptRewind.swift:6), so it lacks 4928's `missing` rule too; port with `deriveRevertTurnCountByUserMessageId` and repository scopes (M, composer lane) |
| 6f644f6e91 | #40036 | feat: link a machine through another environment that already links to it | connections | left (M) |
| 6f8282c2c8 | #41837 | fix(web): an IME Escape no longer blurs the file editor | files | holds: the input method takes an IME Esc before the editor |
| 6f94a06384 | #23346 | fix(vcs): explain checkout failures caused by local changes | git | ported 32cc3467 |
| 7105792176 | #42201 | fix(web): notebook previews show a progress bar's last frame | files | n/a (QuickLook previews) † |
| 721542cac7 | #39994 | fix(web): the issue comment composer lines up with the chat composer | issues | ported 59500419 (20pt bottom inset), diff read 2026-11-25 |
| 732c7126c1 | #41595 | fix(web): RTF previews show a bold, italic or underlined emoji as one character | files | n/a (QuickLook previews) † |
| 7380740efe | #42499 | fix(web): pooled limit refill shows when it lands again | usage | ported 8f1d707d |
| 739bc7adb5 | #42493 | feat(web,mobile): Pierre icons for test files, Vitest, Rolldown and more | files | ported b36ec05c (the 9 filled t3-file-icon-* symbols and tables) and 57524d5b (the 18 stroked and 24px symbols: video, documents, Java, TOML, diff, XML and the rest) |
| 73bb8ece1f | #41228 | fix(web): accept TIFF files containing standard IFD tag type 13 (SubIFDs) | files | n/a (QuickLook previews) † |
| 75443857dc | #42085 | fix(web): Settings text typed before Navigation: Back is saved | shell | ported c74b9ef5 |
| 77c230e456 | #41511 | fix(web): notebook previews show errors saved without a traceback | files | n/a (QuickLook previews, diff read 2026-11-25) |
| 77d299cc1c | #29438 | fix(web): closing the last open pull request clears it from the list | pull requests | already (PullRequestsPage resets the priority groups to empty whenever the feed answers no rows, project errors or not), diff read 2026-11-25 |
| 784da01b29 | #41749 | fix(web): Esc in Find in PDF clears it without closing the sheet | files | n/a (CW's PDFKit preview has no find field) |
| 7913360b2e | #41876 | fix(server): saving a voice key reference needs provider management | settings | port (1.8) † |
| 7922611cee | #37978 | fix(i18n): correct wrong and ambiguous Simplified Chinese strings | other | n/a (translation strings) † |
| 7997916673 | #41505 | fix(web): Markdown previews load relative images in timestamped and root folders | files | ported 9ee37242 |
| 7be3a767cc | #42515 | feat(server): workflow questions take described choices, required reasons, links, and keep who answered | workflows | port (8.3) |
| 7d3677fe70 | #40389 | fix(web): picker branch switches no longer re-read the full local status | git | n/a (CW has no stale-ref reload after a picker checkout to skip), diff read 2026-11-25 |
| 7dd35d324d | #41742 | fix(server): link codes and guest links require the access they hand out | connections | n/a (server side, wire) † |
| 7e004b80e2 | #39142 | fix(client-runtime): a chat file link opens a file that overlapping projects both list | other | ported earlier (T3Store/WorkspaceLinkLookup.swift `pickProjectLinkMatch`, checked 2026-11-25) |
| 7e0d1cb9ba | #42548 | fix(web): Link PR dialog stops duplicate Enter submits and locks input | pull requests | ported dbb2df1b (Enter repeats were already guarded by `pending`) |
| 7ef0558f75 | #40177 | fix(desktop): preview tabs drop a destroyed webview's WebContents | browser | n/a (Electron only) † |
| 7ef7ba0e3b | #40304 | perf(server): a tracked file's Diff panel patch skips the untracked-file listing | git | n/a (CW reads the whole preview, no per-file patch reads to send changeType with) |
| 803f21f6a5 | #39213 | test: pull request Code tab keeps a hidden test file open through collapse all | pull requests | n/a (test only) † |
| 80cf4f7945 | #39260 | fix(web): the terminal button reopens the drawer after its last terminal closed | terminal | already (closing the last terminal resets the drawer; no server listing to go stale), test in 47d4ad86 |
| 8238dc2652 | #39648 | fix(web,mobile): make comment and review author lines headings | pull requests | left: VoiceOver headings for comment and review author lines (S) |
| 830c11ccc2 | #41686 | fix(web): Esc while adding or editing a custom model no longer closes Settings | settings | port (1.3) † |
| 83990ad9a2 | #42272 | fix(server): notebook attachments show a progress bar's last frame | files | n/a (QuickLook previews) † |
| 849d19447f | #42129 | fix(web): Esc clears the Voice model search without closing Settings | settings | port (1.3) † |
| 86272b11f0 | #42419 | fix(web): keybindings search ignores modified Esc and keeps focus on a held Esc | settings | port (1.3) † |
| 887e3a569f | #41216 | fix(web): file picker highlights stay on the typed letters after İ | files | ported 9ee37242 |
| 8987ba39d4 | #42517 | feat(workflows): a run can declare its subject and be found by it | workflows | port (8.5) |
| 898c22f990 | #39639 | fix(scheduled-tasks): clearing a task's thread no longer keeps the old one | scheduled tasks | n/a (wire B1) † |
| 8b70e73371 | #42215 | fix(web): an unfinished PR inline comment survives a refresh that changes the diff | pull requests | ported da18c3b2 (the draft drop) and 9e30cb36 |
| 8b8ec75b01 | #41937 | fix(web): copied startup error details no longer end in a broken character | shell | n/a (web boot error) † |
| 8e8ff9b243 | #39426 | feat: link several environments at once | connections | left (M) |
| 8ee2a8a9a0 | #40437 | fix(web): RTF previews no longer join text across section and column breaks | files | n/a (QuickLook previews) † |
| 8f34bb193a | #42470 | fix(web): ArrowUp in a menu search field moves to the last item | shell | already (MenuView move(-1) with nothing highlighted takes the last item), diff read 2026-11-25 |
| 8f5fd287a4 | #42837 | fix(web,mobile): Usage says "1 session", not "1 sessions" | usage | ported 8f1d707d |
| 902d369808 | #42342 | fix(web): new-commits banner on a PR spans the full header width | pull requests | ported d727914e (with the banner) |
| 904e2671ca | #40585 | fix(web): Keep background announcements quiet for held or stopped runs | shell | n/a (CW has no background thread announcer, BackgroundThreadAnnouncer.tsx) |
| 908e02ee6a | #30925 | fix(web): resetting a setting no longer jumps the Settings page | settings | port (1.8) † |
| 90e6e3e69d | #42244 | fix(web): keep emoji intact in manually added folder names | other | n/a (Swift Characters) † |
| 916fcdc364 | #39312 | fix(web): preserve newer project action drafts when imports fail | settings | port (1.8) † |
| 91d2d90f46 | #26451 | fix(web): a failed main chunk load reloads once instead of showing the boot error | shell | n/a (web chunk load) † |
| 93b8dc3465 | #40494 | fix(web): Antigravity settings show only the fields the chosen sign-in method uses | settings | port (1.8) † |
| 962bda2eb7 | #41489 | test(web): open history documents without reloading the app in iframes | other | n/a (test only) † |
| 966e422c9f | #39769 | fix(desktop): Cmd+T opens the new-tab menu from a focused browser page | shell | already (a focused streamed page leaves keys to the window dispatcher), diff read 2026-11-25 |
| 9842ca0c12 | #42120 | fix(web): an image no longer jumps while its pane is resized | files | already (NSImageView scales in its own bounds, FileSurfaceView.swift:316-330) |
| 98d940f6b2 | #42332 | fix(web): an IME Escape no longer closes the theme editor or ends inspection | settings | port (1.3) † |
| 9904124683 | #41540 | fix(web): EPUBs with a percent-encoded package path open in the file preview | files | n/a (QuickLook previews) † |
| 9a3ad0bec2 | #42986 | fix(web): recognize composerEmpty in keybinding settings | settings | ported d476c29f |
| 9a87dbb99a | #41194 | fix(web): chat file tooltips open beside the link instead of sliding in from the corner | files | holds: CW tooltips anchor to the hovered link view |
| 9b8ab94b24 | #41603 | fix(i18n): hyphenate German compounds built on multi-word terms | other | n/a (translation strings) † |
| 9c8f6427ab | #42276 | fix(web): a cached image no longer flashes at full size in the file preview | files | already (the image is set scaled after it decodes, FileSurfaceView.swift:326-330) |
| 9ca304dabe | #42449 | fix(web): Enter connects in the text generator wizard | connections | port (7.5) † |
| 9d0dd0f9c6 | #41790 | fix(web): Esc while resizing a spreadsheet column or row cancels without closing the sheet | files | n/a (QuickLook previews) † |
| 9d3195b49d | #42000 | fix(web): IME keys no longer cancel or send a diff comment | pull requests | already (marked text takes Esc and Return before `doCommandBy`, DiffReviewAnnotationView.swift:71) |
| 9d78db0af8 | #39937 | fix(web): pull requests linked from an issue open beside it on the Issues page | pull requests | ported 29ce23f3 |
| 9dc36169b4 | #41193 | fix(web,mobile): translate remaining untranslated workflow, git, and link strings | other | n/a (translation strings) † |
| 9de5a941ea | #42870 | perf(web): Files panel Refresh reads only the folders on screen | files | ported 13e961d3 (the unchanged-listing skip is not ported: CW redraws only visible rows) |
| 9fae2cc228 | #41526 | fix(web): accept TIFF Exif and GPS pointers stored as IFD type 13 | files | n/a (QuickLook previews) † |
| 9fde959ac0 | #38799 | feat(web): choose which projects the issues list shows | issues | ported 93e4e41a |
| a0ef9d8d95 | #39574 | fix(web): editable file drag selection no longer breaks across virtualized scroll windows | other | n/a (pierre virtualization; TextKit drag selection spans the file) |
| a149bdc4f6 | #42321 | fix(web): Voice Models language menu resets its search filter on close | settings | port (1.8) † |
| a2231ca59b | #42417 | fix(web): Cmd/Ctrl+W closes the active tab on the Issues page | issues | ported 59500419, diff read 2026-11-25 |
| a23085273f | #33279 | fix(web): adding the last snooze option no longer reorders rows mid-edit | settings | port (1.8) † |
| a3001b33fe | #40468 | fix(web): RTF previews break the line at TextEdit soft line breaks | files | n/a (QuickLook previews) † |
| a5d86e6382 | #41844 | fix(web): Push on the default branch no longer commits files changed while confirming | git | ported eda2a88d |
| a686952304 | #42725 | fix(web): EPUB chapter titles no longer end in a broken emoji | other | n/a (Swift Characters) † |
| a68a3539b8 | #41815 | fix(web): holding Esc in the Files search clears it without closing the sheet | files | ported 9ee37242 |
| a76e554784 | #42935 | test(web): Files panel Refresh test no longer fails on a late tree render | other | n/a (test only) † |
| a8363dad7f | #40808 | fix(web): keybindings using '+' show a plus keycap instead of empty pills | settings | ported d476c29f |
| a8f5237a3c | #39926 | fix(web): repository and loading-header PR links honor 'Open links in' | pull requests | ported 7835705c |
| a9bec41729 | #41547 | fix(web): Office previews open files with malformed external links or spaced sheet names | files | n/a (QuickLook previews) † |
| aa725f4bd4 | #39616 | fix(web): file find scrolls to matches below wrapped lines | other | ported fdd1f7f8: a match lays out every line above it before it scrolls |
| aacdaba15c | #42852 | fix(web): panel resize handle no longer covers the chat scrollbar on touch devices | shell | n/a (touch devices) † |
| ac3af66f21 | #41901 | fix(web): a copied issue or pull request error no longer ends in a broken character | other | n/a (Swift Characters) † |
| acd4fc67b9 | #42884 | fix(web): show Labs device preferences read-only for projects | settings | port (1.8) † |
| aced664ed9 | #39024 | fix(client-runtime): prefer newer completed compaction over stale liveUsage | other | n/a (server only, wire) † |
| ae926f6579 | #41852 | fix(web): Cmd/Ctrl+F opens the browser find bar while a pull request is maximized | shell | n/a (CW's Pull Requests page has no right panel to maximize over its list), diff read 2026-11-25 |
| b042e4ee75 | #42722 | fix(web): hide the right panel add-surface menu when no surfaces are available | shell | already (Device is always available beside a thread, so the + menu is never empty), diff read 2026-11-25 |
| b125918f4b | #42718 | fix(web): xlsx previews no longer fail on cells truncated mid-emoji | files | n/a (QuickLook previews, diff read 2026-11-25) |
| b2d51f35bb | #42224 | fix(web): a held Esc closing a nested menu or dialog no longer closes Usage or Settings | shell | already (AppRouteModalView ignores Esc repeats), diff read 2026-11-25 |
| b427708979 | #40299 | fix(issues): agents can file issues in any bound Linear team | issues | n/a (agent tool, server) † |
| b4345bf904 | #41702 | fix(web): terminal copy shortcuts no longer type escape codes when nothing is selected | terminal | already (SwiftTerm disables Copy without a selection and drops Cmd keys), diff read 2026-11-25 |
| b479ce21ed | #21667 | fix(client-runtime): stop sessions on incompatible server configuration | other | n/a (server only, wire) † |
| b4a5a4927f | #42915 | fix(web): reading position survives a panel resize right after a thread opens | shell | port (thread note 1.10) † |
| b51399fb38 | #42093 | fix(web): a held Esc or a search of spaces no longer closes Settings | settings | port (1.3) † |
| b5481adcd8 | #32841 | fix(web,mobile): scheduled tasks from Settings start from the project's default branch | scheduled tasks | ported 54702697 |
| b568fcbaa6 | #40023 | feat(issues): a project can list issues from several Linear teams | issues | ported 31648718 |
| b61af8a5d2 | #42863 | fix(web,mobile): mixed add/delete review selections no longer show backwards line ranges | pull requests | ported c3aa76c5 |
| ba37a1afa1 | #41714 | fix(web): the PR checks count says how many are running instead of done/total | pull requests | ported fc8c0c41 |
| ba588ef663 | #24034 | fix(web): match macOS Option shortcuts to the active keyboard layout | settings | already (charactersIgnoringModifiers reads the active layout) |
| babc83baf1 | #39315 | fix(web): PR viewer renders GitHub :emoji: shortcodes | pull requests | ported a7e4aadb |
| bac86471fe | #40507 | fix(web): links inside a PDF are clickable in the in-app PDF viewer | files | n/a (PDFKit links are clickable) |
| bc13afaa3c | #40965 | Invalidate pending theme imports when a replacement is too large | settings | port (1.8) † |
| bc6062805d | #39057 | fix(web): preserve file preview selection after scrolling back | files | holds: an NSTextView keeps its selection across scrolling (diff read 2026-11-25) |
| bd3e495b5f | #42442 | fix(web): mod+f opens find in read-only source previews | files | ported 311e739a, then fdd1f7f8: T3 shows the diff view's search panel (`StyledDiffCodeView`), so CW shows `DiffFindWidget` instead of AppKit's find bar |
| c14e9f9717 | #42810 | fix(server): preserve split terminal control sequences across scrollback clears | terminal | n/a (server only) † |
| c198f73b37 | #40776 | fix(web): a click outside the project action editor no longer discards the draft | settings | ported 5dc3ddd9 |
| c39c21f870 | #42361 | fix(web): Esc in a font family field closes Settings when no edit is pending | settings | port (1.3) † |
| c43e073123 | #39319 | fix(web): Arrow and page keys scroll the pull request pane after a click or when it opens | pull requests | ported 92620f14 (Summary and Timeline take keyboard focus on a click; opening the pane does not move focus yet) |
| c478fde9fe | #42791 | fix(web): bad workflow pane links no longer pick the first tab or crash | workflows | port (8.6) † |
| c5dc20f9f5 | #37191 | fix(client): new threads from a grouped repository start in its root checkout | shell | ported 0e916fe4 |
| c6162da7ec | #42353 | fix(server): skipped workflow runs no longer keep their webhook payloads forever | workflows | port (1.7) |
| c6ca01b373 | #40516 | fix(web): preserve newer navigation when reopening closed views | shell | ported 71bdfaed (newer navigation already wins; the failure toast) |
| c8014ad590 | #42622 | fix(web): project name field restores the saved name when cleared | settings | port (1.8) † |
| c8625cafce | #34588 | fix(web): Ctrl+B reaches a focused terminal again | terminal | ported 04b7ee0f |
| c8f8ad17ac | #41277 | fix(web): RTF previews open files that declare code page 0 or 866 | files | n/a (QuickLook previews) † |
| c991a91ec6 | #42827 | fix(web): GB18030 RTF files now preview instead of showing no preview | files | n/a (QuickLook previews) † |
| c9e9e7d36a | #40708 | fix(web): a click outside the scheduled task editor no longer discards the draft | scheduled tasks | ported 5dc3ddd9 |
| cb207e9f60 | #42228 | fix(web): long Issues and Pull Requests searches no longer end in a broken character | other | n/a (Swift Characters) † |
| cb2a488c67 | #39302 | fix(web): an off-track desktop build no longer says "Up to date" | shell | n/a (Electron updater) † |
| cbf4ea7ddc | #41264 | fix(web): shift-scroll and horizontal scrollers no longer navigate history | shell | n/a (web history swipe) † |
| ccabed086a | #39445 | feat(web): the environments page is a map of your machines | connections | left (Environments map, L) |
| cef38e408d | #42805 | fix(web): file picker highlights no longer break emoji in file names | files | ported 9ee37242 |
| d15123668e | #39579 | fix(web): keep reopened pairing link dialogs open on completion | connections | port (7.5) † |
| d1f8636f49 | #39225 | fix(mobile,web): quote and port messages are translated in every language | other | n/a (translation strings) † |
| d20e6c294c | #39884 | fix(speech): project name hints no longer recase ordinary words | settings | port (1.8) † |
| d244be81ba | #41784 | fix(web): an IME Escape no longer clears the keybindings search | settings | ported cb5edfe1 (an IME Esc passes to the input method) |
| d49cf0bab5 | #41692 | fix(web): a second Escape in the theme CSS editor closes the theme editor | settings | port (1.3) † |
| d5f8a7573a | #40264 | fix(web): RTF previews hide tracked deletions | files | n/a (QuickLook previews) † |
| d63b9c4c76 | #41353 | fix(web): retry a failed port-forward locality probe | connections | port (7.5) † |
| d6cdb4f161 | #39554 | fix(web): scope checkout errors to the selected pull request | pull requests | ported 621628ec |
| d73e41a3fa | #41931 | fix(web): Esc in pull request search clears it instead of leaving the page | pull requests | ported 65cd07a1 |
| dbee5a0af0 | #38911 | fix(mobile,web): saves, account switches and registrations report their own outcome | connections | port (7.5) † |
| dc326236ea | #42055 | fix(web): raw HTML paragraphs and list items keep their lines when line breaks are on | files | n/a (QuickLook previews) † |
| dc5ae5ce63 | #42991 | fix(web): empty ODS sheets show 0 columns instead of 1 | files | n/a (QuickLook previews) † |
| dc7b8802b8 | #42356 | fix(connect): respect relay tracing opt-outs and remove machine details | shell | n/a (telemetry) † |
| dca3ab2025 | #42757 | fix(web): held overlay and Usage shortcuts no longer flicker | shell | ported e9ebf28f |
| def64e3a54 | #41117 | fix(web): clicking the selected file in a Files folder view opens it | files | holds: every row click calls onOpenFile, selected or not |
| dffbfdfc00 | #42305 | fix(web): shell calls without -c no longer add agent working folders | other | n/a (server only, wire) † |
| e166aa1db1 | #41579 | fix(desktop): swiping sideways over a confirmation dialog no longer goes back or forward | shell | n/a (Electron only) † |
| e242ed0e1a | #42973 | fix(web): exact 1,024-column CSV and TSV files no longer show the truncated-columns banner | files | n/a (CW table caps at 30 columns with its own notice) |
| e25a337e5f | #39493 | fix(web): keep long-named VS Code themes separate on import | settings | port (1.8) † |
| e2c3c4250d | #31561 | fix(preview): streamed browser tabs show native select menus | browser | ported 12a642d9 |
| e2e8a49d97 | #41537 | fix(web): a PDF keeps its place when the pane is resized | files | n/a (PDFKit keeps its place) |
| e36800e61b | #42950 | fix(web): SQLite 1-byte BLOB previews show "[blob: 1 byte]" | files | n/a (QuickLook previews) † |
| e3b79cd0bf | #41767 | fix: Windows system tools run by absolute path, and mobile links and shares are handled more strictly | other | n/a (server only, wire) † |
| e3f7eb5085 | #42851 | fix(web): Changes pane explains a diff of only hidden test files | files | ported adb9469d |
| e3f9db2447 | #40741 | fix(server): TanStack Source pull requests open from every client, and private ones work end to end | pull requests | n/a (env-gated forge) † |
| e4da383485 | #42467 | fix(web,mobile): CJK project names get a one-character monogram | settings | port (1.8) † |
| e62e5122ad | #42262 | fix(web): a held Esc in a nested panel control no longer closes the right panel sheet | shell | ported 1cba774b |
| e668e6141f | #39840 | fix(web): scrolling a PR description no longer moves focus to the condensed header | pull requests | n/a (condensing moves no AppKit focus, diff read 2026-11-25) |
| e86a9c5169 | #41585 | fix(web): OpenDocument previews keep merged table cells | files | n/a (QuickLook previews) † |
| e87df609e6 | #42329 | fix(web): large SVG project icons come back after their link expires | files | already (CW fetches the bytes as soon as it signs the URL and keeps the bitmap, ProjectIcons.swift:96-122) |
| e97e360cfc | #39967 | fix(web): Option + a letter records the letter, not the macOS glyph | settings | already (charactersIgnoringModifiers drops Option) |
| ece5f21b17 | #42311 | feat(connect): tell people when a new T3 Connect device signs in | connections | ported ed63905b |
| efea1aabe7 | #40381 | fix(web): CSV preview rows keep their height during horizontal scroll | files | already (DelimitedTableView measures every cell of a row, so rows never change height on scroll), diff read 2026-11-25 |
| f15d908759 | #42027 | fix(web): Esc in voice alias input cancels it without closing Settings | settings | port (1.3) † |
| f1c13177d8 | #41263 | fix(web): spreadsheet text and fills no longer vanish when their cell scrolls out | files | n/a (QuickLook previews, diff read 2026-11-25) |
| f1efcfb494 | #42855 | fix(client-runtime): feedback trace shows "1 character", not "1 characters" | other | n/a (server only, wire) † |
| f30874fef7 | #41756 | fix: remote logins and webhook tokens stay with their own host and reader | connections | n/a (server side, wire) † |
| f46f17e46f | #37358 | fix(web): small buttons leave room between icon and label | settings | port (1.8) † |
| f60c747568 | #39815 | fix(web): open PDF attachments no longer reload while the agent works | files | holds: CW reads an open PDF again only on Force Reload |
| f811978eef | #42395 | fix(web): Esc in Theme Editor color filter clears the filter without closing the editor | settings | ported cb5edfe1 |
| f82de6567c | #41775 | fix(web): restoring a saved model mapping clears its typed prices | settings | port (1.8) † |
| f89883c568 | #39875 | fix(web): a long commit name no longer runs under the PR code tab's icons | pull requests | ported 4b07f98d (the commit menu gives way before the counts), diff read 2026-11-25 |
| f8f4a0b057 | #29261 | feat: Verilog, SystemVerilog, and VHDL code is syntax highlighted | composer | ported 17a38daa (CW's own highlighter gets two profiles), diff read 2026-11-25 |
| f9f34aab78 | #41361 | fix(web): start without WebAssembly by initialising Words in a guard | shell | n/a (web only) † |
| fa2ee196b5 | #41539 | fix(web): archived threads settings stay responsive with thousands of threads | settings | ported c82cac6d |
| fa9f154e1b | #41949 | fix(web): the Cite button appears when a selection ends on a file chip's icon in Firefox | files | n/a (Firefox selection quirk) |
| fb4558d77d | #40631 | fix(web,mobile,server): large files load in full without freezing the file preview | files | ported 7bb75df1 (no chunked Markdown or plain paged viewer; past the caps the 1 MB preview stays) |
| fbd939eb4c | #42598 | fix(web,mobile): author avatars keep emoji initials whole | pull requests | already (Swift prefix takes a whole grapheme), diff read 2026-11-25 |
| fd4284d8b2 | #40556 | fix(vcs): refresh branch pickers after external worktree changes | git | already (both pickers re-read status or refs on open; the digest change is server side), diff read 2026-11-25 |
| fd44bde571 | #41383 | fix(web): keep OpenDocument image descriptions in alt text | files | n/a (QuickLook previews) † |
| fdcb71a476 | #41764 | fix(web): Esc in theme search clears it without closing the dialog | settings | port (1.3) † |
| ffb42a0b77 | #40543 | fix(web): preserve browser history across open tabs | browser | n/a (one in-process history store; T3 merges across web tabs), diff read 2026-11-25 |

## 12. Port order

Sorted by how much a daily user sees it. S, M and L are the sizes above.

1. 7.1 Environments map (L, redesign). Every visit to Settings, Environments changes.
2. 7.4 New device toast (S).
3. 2.2 Checks count label (S). Shows on every PR header, so recapture that reference.
4. 2.1 Stack menu (M).
5. 3.1 Copy contents (S).
6. 2.7 Issues project filter (M), then 1.5 Linear accounts and teams (M).
7. 1.1 Keybinding action search (M), then 1.2 keybinding keys (S).
8. 3.2 Large files in full (M).
9. 1.3 Esc and IME rule (M). One shared change, then a spot check per field.
10. 7.2 Link several environments (M) and 7.3 link through another environment (M). They need 7.1 for the drag gesture and work from the list without it.
11. 6.1 Browser history (M), 10.1 Reopen closed view (M), 3.3 Source find (M).
12. 2.3 Review drafts persist (S), 2.4 Open links in (S), 1.4 Scheduled tasks (S), 1.6 Archived threads (S).
13. The rest: 2.6, 1.8, 3.4 to 3.7, 4.1 to 4.3, 5.1 to 5.3, 6.2, 6.3, 7.5, 9.1, 9.2, 10.2 to 10.6.
14. Workflows (8.1 to 8.6, 1.7) last, and only after the user decides CW needs Workflows. 8.1 is L, 8.3 and 8.4 are M, 8.2, 8.5 and 8.6 are S, so the group adds up to about 4.3 hours.

Sizes per area, counting 15 minutes per S, 45 per M and 2 hours per L.

| Area | S | M | L | Agent time |
|---|---|---|---|---|
| Settings (1.1 to 1.8) | 4 | 4 | 0 | about 4 h |
| Pull requests and issues (2.1 to 2.7) | 3 | 3 | 0 | about 3 h |
| Files and diff (3.1 to 3.7) | 5 | 2 | 0 | about 2.8 h |
| Git (4.1 to 4.3) | 3 | 0 | 0 | about 0.75 h |
| Terminal (5.1 to 5.3) | 3 | 0 | 0 | about 0.75 h |
| Browser (6.1 to 6.3) | 2 | 1 | 0 | about 1.3 h |
| Connections (7.1 to 7.5) | 2 | 2 | 1 | about 4 h |
| Workflows (8.1 to 8.6) | 3 | 2 | 1 | about 4.3 h |
| Usage (9.1, 9.2) | 2 | 0 | 0 | about 0.5 h |
| Shell and dialogs (10.1 to 10.6) | 5 | 1 | 0 | about 2 h |
| Total | 32 | 15 | 2 | about 23.3 h |

Plus about 1 hour of review for the fidelity recaptures in 2.2, 2.1 and 7.1. Excluding Workflows, the total is about 19 hours. Items that need a 5258 server field first: 7.1 and 7.3 (wire A6), 6.3 (preview stream), 8.3 (workflow questions), 1.7 and 8.x (workflows capability).

## What I could not settle by reading

- How 7.1's layout engine places machines and stacks. I read the toolbar, legend, styles and strings, not `environmentsMap.logic.ts` (1,979 lines).
- Whether CW already persists PR review drafts (2.3), stores browser history the way T3 does (6.1), or routes every "Open links in" site through one router (2.4). I did not open those CW files.
- Which of the 254 † rows hold a visible change that the subject hides. The ones most likely to: 1.3's ~25 Esc commits, 2.6's PR fixes and 3.4's tree fixes. Read each commit when you port it.
- Whether #26760 (PR file order moved to client-runtime) changes web behavior. I read the stat only.
- Whether CW has a language setting (5.3).
- Whether workflow question fields are in the wire note. I did not grep it (8.3).

## Corrections from the settings and connections port (2026-11-25)

- 1.1 says a send-shortcut pair differing in `composerEmpty` does not count as a conflict. The #28612 hunk changes the add-row's shortcut chips instead: with the multiline send mode a binding shows both of its shortcuts (`previewLabels`, KeybindingsSettings.logic.ts:307-326). `keybindingConflictLabels` has no `composerEmpty` rule.
- 1.1 misses that the Command combobox is `defaultOpen`: a new row opens with its search focused.
- 1.2: CW already records the active layout's letter under Option, because `charactersIgnoringModifiers` drops Option (#39967, #24034).
- 1.4: #30253 needs the composer's traits picker inside the task editor, so it is M, not part of an S batch.
- Section 1 misses five 5258 settings rows, all in `settingsSearch.ts`: Projects > Repositories (`project-repositories`, #35925), Access > Preview tunnel (`preview-tunnel`, #39415), Chat > Open subagents and side chats in (`side-thread-open-target`, #39515), Appearance > HTML preview width (thread note 1.16) and Labs > Agent feedback (thread note 1.5). They stay out of CW's search through `UNPORTED_IDS` until their rows land.
- The five rows above are ported: Preview tunnel 61294005, the side chat target, HTML preview width and Agent feedback a2b09b17, Projects > Repositories 640d7b91. Agent feedback reports go out through the server's analytics service (FeedbackStore.ts:208), so CW hides the row for servers it starts.
- 1.1's second send-shortcut chip under multiline send is ported in a56e4677.
- 7.4's Review opens Access for the primary environment only: CW's Access page has no environment picker (T3's `accessEnvironmentPicker`, ConnectionsSettings.tsx:1293). Opening it for the toast's environment needs that picker first (M).
- 1.7 stays unported until CW has Workflows: the row returns nothing unless `workflowsEnabled` is on.
- 1.3 is partly ported (cb5edfe1): settings search fields clear on Esc and an IME Esc reaches the input method. The rows outside Settings (Files, PR, diff comments, dictation, right panel sheet) and the font family, voice and custom model rows stay open.

## Corrections from the panels port (2026-11-25)

- #41073 (not in the table, 7103527dcc): T3 resolves a PR description's relative file link against the PR checkout before it opens the Files panel. CW's PR markdown has no `onOpenFile`, so its file links never open the panel at all and go to the editor. Left: wire PR markdown to the thread's Files panel with the checkout-relative path (M).

- 2.5: #26760 is not `n/a`. CW never had T3's review order (`orderDiffFiles` was already in 4928's web client), so the Code tab now runs `orderDiffFilesForReview` (da18c3b2).
- 3.5: #39497 changes the web picture-in-picture's PDF embedding, not the file preview. CW never embeds preview PDFs.
- 3.6: the file icon generator read two hard-coded T3 entries and missed every `t3-file-icon-*` symbol; it now reads T3's tables from `pierre-icons.ts`. #29261 (Verilog and VHDL highlighting) is still unread.
- 5.1: the T3 bug is a stale server listing in `terminalUiStateStore.ts`. CW keeps no such listing, so the button already reopened the drawer.
- 6.1: CW keeps one browser history per process, so T3's merge across web tabs has nothing to merge.
- 6.2: #26965, #36286 and #42445 are the desktop's hosted webview and the client recording compositor, which CW lacks. #42480 is the settings row in 1.8.
- 10.1: #42875 and #42745 assume a closed-tab stack on the Pull Requests and Issues pages. CW remembers closed thread panel tabs only.
- 10.4: T3's Device entry is available whenever a thread is open, so the + menu only empties without a thread, where CW shows no panel.
- 10.5: CW has app zoom in the View menu, and `previewFocus` covers only the browser view, so #39207 already holds.

## Corrections from the third panels port (2026-11-25)

- 2.6: #39840 adds DOM focus markers for the condensed header swap; AppKit focus never moves when the header condenses, so it is `n/a`.
- 2.6: #42342 and #41773 sit on #41761 (78cffe29ec), which adds the head pin and the "New commits were pushed" banner. The thread note listed #41761 as `n/a (pull requests, other agent)`; it is ported in d727914e.
- 3.3: CW's source preview is a TextKit view with the system find bar, so #39616, #39057 and #39574 hold without code. Only Cmd+F routing was missing: it went to thread find.
- 3.3, fourth panels port: T3 5258 renders read-only sources through `StyledDiffCodeView` (ReadOnlySourcePreview.tsx), so Mod+F opens pierre's search panel, the one the diff panel shows, not the thread's find bar. CW's sources now show `DiffFindWidget`. CW's diff panel painted matches in system yellow; both now use T3's `--diffs-bg-search-match-override` colors (StyledDiffCodeView.tsx:24-33).
- 3.4: #42932 changes `AttachmentFilePreview`'s fallback text, which CW replaces with QuickLook. #39142 was already ported. #42682 was already ported (62cbede9).
- 3.4: CW resolved a Markdown preview's relative images against the project root, not the file's folder, before 5258 too (fixed with #41505).
- 10.1: #42875 and #42745 are ported with the base feature: the pages' tabs join the closed-tab stack under `page:` keys.
- The usage capability: a 5258 server filters only the settings payload by `httpUsageLimitSources` (serverSettings.ts:167-175); snapshots carry `http` sources regardless.
- #41073 (7103527dcc): ported in 54663722. PR Markdown asks the pull request view to open its file links, resolved under the body's checkout.
