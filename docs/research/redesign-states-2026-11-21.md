# Redesign states, 2026-11-21

Every place the app shows an empty, loading, failed or disconnected state, what it shows today, and what Redesign
(theme `candywrapper-dither`) shows after this pass. The user asked for "designed states for empty, loading and error":
an icon, one plain sentence and one action, never a raw error name, a sentence floating in a void or a bare grey box.

Lines are on branch `states`. Buckets are E (empty), L (loading) and X (error or disconnected). "Changed" means Redesign
draws it with the state view or a skeleton now; the default themes and Glass draw exactly what they drew before.

## The parts

- `EmptyView` (`Packages/CandyKit/Sources/DesignSystem/Components/EmptyView.swift`) was T3's `Empty` and stays that in
  the default themes. Under Redesign it is the state view, laid out in `EmptyViewRedesign.swift`: a Tabler icon on an
  inset card (40pt box and 20pt icon for a panel, 32 and 16 for a card, a bare 14pt icon in a row), the title at 14 or
  13 and 500, the sentence at 13 or 12 in the muted color, then one outline button. `.default` is the panel size,
  `.compact` the card, and the new `.inline` a single row with the action at the right. `.hero` keeps T3's look.
- `StateCopy` carries Redesign's title, sentence, icon and `details`, the raw error text. Details shows behind a
  Details button that opens a mono block, and as the view's tooltip. `StateAction` is the one action.
  `redesign` and `action` show only under Redesign, so a caller can set them without touching the default themes.
- `StateSkeletonView` (`StateSkeletonRedesign.swift`) is the loading placeholder: bars in the pressed fill shaped like
  a diff, a list or a conversation. It breathes once every 2.4 s through `LoopingAnimation`, so it stops when hidden,
  out of a window, occluded or under Reduce Motion, and the owner removes it when content arrives.
- `StateErrorText` (`Packages/CandyKit/Sources/Features/States/StateErrorText.swift`) turns an error into `StateCopy`.
  The app's diff loaders now throw `ThreadSession.DiffLoadError`, which keeps the `RPCTypedError` (`TypedErrorCarrying`).

## Error mapping

Tags from `packages/contracts/src/vcs.ts:61-290` and the client's own. The raw tag and every field go to Details.

| Tag | Title | Sentence |
|---|---|---|
| `VcsProcessSpawnError` | Git could not start | Git could not be started in `<cwd>`. Check that git is installed and the folder still exists, then retry. |
| `VcsProcessExitError`, authentication | Git could not sign in | The remote refused git's credentials in `<cwd>`. Sign in again, then retry. |
| `VcsProcessExitError`, rate-limited | Rate limited | The remote's API rate limit was reached. Wait a minute, then retry. |
| `VcsProcessExitError`, not-found | the caller's | the server's `detail` |
| `VcsProcessExitError`, other | the caller's | Git exited with code N in `<cwd>`. Retry, or open Details for git's output. |
| `VcsProcessTimeoutError` | Git timed out | Git took too long to answer in `<cwd>`. Retry in a moment. |
| `VcsProcessOutputLimitError` | Too large to show | Git's output was larger than the server allows. Narrow the selection, then retry. |
| `VcsProcessStdinWriteError`, `VcsProcessOutputReadError`, `VcsProcessMissingExitCodeError` | the caller's | Git stopped before it finished in `<cwd>`. Retry. |
| `VcsRepositoryDetectionError` | Not a git repository | `<cwd>` is not inside a git repository, so there are no changes to show. |
| `VcsUnsupportedOperationError` | Not supported here | the server's `detail` |
| `VcsCheckpointStorageError` | the caller's | The server could not store this turn's checkpoint in `<cwd>`. Retry. |
| `GitCommandError`, `GitManagerError` | the caller's | the server's `detail` |
| `EnvironmentRpcUnavailableError` | Not connected | The environment is not connected. It reconnects on its own. Retry once it is back. |
| any other tag with a sentence `message` | the caller's | that message |
| any other tag, or bare text shaped like a type or code | the caller's | The server returned an error without a reason. Retry, or open Details to report it. |

The caller's title says what was being done: "Could not load changes", "Could not list files", "Could not load issues".
An error toast whose message is a bare type or code shows "The request failed without a reason. Open the details to
report it." with the raw text under Show details (`ToastView`, Redesign only).

## Inventory

### Diff panel (`Features/Diff/DiffPanelView.swift`)

| Line | Today | Bucket | Redesign now |
|---|---|---|---|
| 77, 604, 694 | "Loading tool call diff...", "Loading checkpoint diff...", "Loading changes..." / "Loading uncommitted changes..." centered | L | changed: diff skeleton |
| 71, 78, 86, 108, 683, 690, 731 | "No patch available for this selection." alone in the middle | E | changed: "No changes to show", Pick another turn or scope |
| 108, 611, 726 | "No net changes in this selection." | E | changed: "No net changes" |
| 600 | "No completed turns yet." | E | changed: "No completed turns yet", with when they appear |
| 123, 621, 723 | the RPC text in red at the top left (`VcsProcessSpawnError`), then the no-patch line | X | changed: mapped error, Retry runs the same request, raw tag in Details |
| 673, 674 | "Loading commits...", "No commits on this branch." in the Commits submenu | L, E | left: menu rows, one line is right there |
| 997 | find widget "No results" | E | left: a counter inside the find field |

### Files (`Features/Files/`)

| Line | Today | Bucket | Redesign now |
|---|---|---|---|
| FilesPanelView.swift:67, 118 | "Loading files…" line | L | changed: list skeleton before the first listing; a refresh with a tree on screen keeps T3's line |
| FilesPanelView.swift:110 | the error in red plus " Click to retry." | X | changed: mapped error and Retry (`onRefresh`) |
| FilesPanelView.swift:121 | "No matching files." | E | changed: "No matching files" with a hint |
| FilesPanelView.swift:125 | "More matches available. Refine your search." | E | left: a note above real results |
| FileSurfaceView.swift:257 | a lone spinner while a file loads | L | changed: diff-shaped skeleton |
| FileSurfaceView.swift:258, 322, 343 | `FileFailureView`: a red line and path lines | X | changed: "Could not open this file" / "Could not preview this file" / "Could not load this image", the path in the sentence, the rest in Details |
| NativeFilePreviewView.swift:10, 53 | "Loading file preview…", "No preview available. Save the file to open it in another app." | L, E | left: a Quick Look host with its own sizing; next on the list |

### Terminal, browser, device

| Line | Today | Bucket | Redesign now |
|---|---|---|---|
| Terminal/TerminalDrawerView.swift:21 | "No terminal sessions for this thread yet." and New Terminal | E | changed: "No terminals yet", New terminal runs the same action |
| Browser/BrowserPanelView.swift:406 | `EmptyView` "No preview yet" | E | changed: state view, shorter sentence; no action, since the URL field above is the action |
| Device/DevicePanelEmptyView.swift:7, DevicePanelView.swift:63, 129 | "No simulators or emulators were found", "Installing device support…" | E, L | left: its own view with setup buttons; restyle when the device hub gets Redesign work |

### Thread

| Line | Today | Bucket | Redesign now |
|---|---|---|---|
| Thread/ThreadPanelView.swift:597-619 | Redesign shows nothing while a thread's messages load (the "Loading messages..." banner is default-theme only) | L | changed: conversation skeleton, only once the 0.4 s delayed status shows and only while the timeline has no rows |
| Thread/NoActiveThreadStateView.swift:10 | `EmptyView` "Pick a thread to continue" | E | changed through `EmptyView` |
| Thread/ThreadImageGalleryView.swift:56, 73, 188 | "No images yet", "Loading…", "Image unavailable" | E, L, X | 188 changed through `AsyncImageView`; 56 and 73 left (a caption inside the gallery card) |
| Thread/ThreadImageWallView.swift:297, 409 | "Image unavailable" | X | changed through `AsyncImageView` |
| Thread/TimelineWorkInspector.swift:171-176 | "No output.", "Loading output…", "Couldn't load output: …" in mono | E, L, X | left: lines inside a tool's output block, read as output |
| Thread/TimelineWebRows.swift:53, 172, 317 | "Unable to load <title>", "Page unavailable" toast, "Unable to load the <server> app" | X | left: inline rows in the conversation; next on the list |
| Thread/ThreadAssistantCitation.swift:253, 255 | "Could not load the cited response", "The cited response is unavailable" | X | left: already plain, in a popover |
| Thread/ThreadMediaAttachmentView.swift:81 | tooltip "Unable to load audio. Retry playback." | X | left: tooltip on a retry control |
| Thread/ThreadContextWindowMeterView.swift:341 | "No usage reported for this thread yet." | E | left: a note in a popover |
| Git/ThreadLineageWorkflowViews.swift:158 | "No agents yet" | E | left: a 28pt row in the lineage card |

### Images in messages (`Features/Markdown/`, `Features/Composer/ComposerImageShelfView.swift`)

| Line | Today | Bucket | Redesign now |
|---|---|---|---|
| MarkdownMedia.swift:235, MarkdownView.swift:817 | "Image unavailable · <alt> · <reason>" as 12pt text | X | changed: `AsyncImageView` shows the card state (inline row in a small slot), the reason as its sentence, the alt text in the tooltip |
| MarkdownView.swift:820 | "Image unavailable. The file may have been moved or deleted." | X | changed the same way |
| ComposerImageShelfView.swift:113-140 | Redesign's image skeleton shimmer | L | changed: the sweep no longer runs under Reduce Motion |
| MarkdownLayout.swift:1502 | "Unable to render diagram: <message>" | X | left: drawn into the text layout |

### Sidebar and search

| Line | Today | Bucket | Redesign now |
|---|---|---|---|
| Sidebar/SidebarListModel.swift:452, 455 | "No threads yet", "No threads in <project> yet" | E | changed: inline state with an icon (`SidebarEmptyTextRowView`) |
| Sidebar/SidebarListModel.swift:498 | "Searching thread messages…", "Couldn't search thread messages", "No threads found" | L, X, E | changed: inline state; the failure reads "Could not search messages" |
| Sidebar/SidebarSearchRowViews.swift:145 | "No projects yet" and Add project | E | left: already has its action |
| Sidebar/SidebarProjectScopeView.swift:45 | "No matching projects." | E | left: a line in the scope popover |
| Sidebar/SidebarNoProjectsHero.swift:8 | hero "What should we work on?" | E | left: `.hero` keeps its look |
| CommandPalette/CommandPaletteController.swift:230, DesignSystem CommandPaletteView.swift:216 | "No matching commands, projects, or threads." | E | changed: card state with a search icon |
| Git/BranchPickerView.swift:51 | "No refs found." | E | left: a line in the branch picker |

### Pages and Settings

| Line | Today | Bucket | Redesign now |
|---|---|---|---|
| Issues/IssuesPageView.swift:182, 186, 194 | `EmptyView`s: unavailable, "Could not load issues" with the raw message, no trackers | X, E | changed through `EmptyView`; 186 maps its message and keeps Retry |
| Issues/IssueDetailView.swift:128 | "Could not load this issue" | X | changed through `EmptyView` |
| PullRequests/PullRequestsPageView.swift:227-252 | unavailable, no projects, search empty, filtered empty | X, E | changed through `EmptyView`; 227 maps its message, every existing button kept |
| PullRequests/PullRequestDetailView.swift:437, PullRequestDiffUnavailableView.swift:26 | `EmptyView` | X, E | changed through `EmptyView` |
| Settings/SettingsProjectListView.swift:84, 85 | "No projects match", "Add a project from the sidebar to configure it here." centered in a card | E | changed: card state; no action, since Settings has no add-project hook yet |
| Settings/KeybindingsSettingsView.swift:46 | "No keybindings match your search." | E | changed: card state |
| Settings/ConnectionsSettingsView.swift:376, T3ConnectAccountView.swift:131, ScheduledTasks/ScheduledTasksSettingsView.swift:51, SourceControlSettingsView.swift:330 | `EmptyView`s | E, L, X | changed through `EmptyView` |
| Settings/FirstRunRecoveryView.swift:21 | "Still connecting" / "Could not read settings" with Reload | X | changed: state view, Reload or Retry runs `onRetry` |
| Settings/ProjectSettingsView.swift:74 | "Add a project from the sidebar…" as an unavailable message | E | left: shown only inside a project page |

### Toasts (App/Sources, 40-odd call sites)

Most failure toasts already pair a plain title with the error's text, which is a sentence. The ones that pass a raw
RPC description (`ThreadLineageController.toast(_:_:)`, `FilesController.swift:540, 604`, `SideChatController.toast`)
can carry a bare tag. `ToastView` now replaces a bare type or code with a sentence under Redesign and keeps the text
under Show details (X, changed in one place for every caller).

## Counts

84 entries above by surface, counting each line group once: 33 empty, 15 loading, 36 error or disconnected.
Changed: 53 (19 E, 9 L, 25 X). Left: 31, each with its reason in the table: menu rows and counters where one line is
right, popovers and timeline rows that read as content, views with their own buttons already, and three that need
plumbing first (native file preview, timeline web rows, Settings add-project).

## Places the app still says "T3 Code"

82 string literals in App/Sources and Features (`grep -rnE '"[^"]*T3 Code[^"]*"'`, comments and the generated settings
search catalog left out). Most name T3's server or T3 Connect, which is correct. The ones in CandyWrapper's own state
copy, not renamed in this task:

- `Settings/FirstRunRecoveryView.swift:22` "T3 Code could not confirm this workspace." (default themes; Redesign's copy avoids it)
- `Settings/ConnectionDiagnosis.swift:124` "Connect this device to the internet. T3 Code reconnects on its own." and 13 more lines in that file
- `Issues/IssuesPageView.swift:182` "Update this environment's T3 Code server to browse issues." (names the server, fine)
- `App/Sources/ServerController.swift` (6), `Settings/WelcomePageView.swift` (3), `Settings/StorageSettingsView.swift` (3),
  `Settings/GeneralSettingsView.swift` (3), `Settings/DesktopManagedDialogs.swift` (3), `App/Sources/SettingsHostAccess.swift` (3)
