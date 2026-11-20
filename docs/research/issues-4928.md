# Issues in Nightly 4928: plan

This ports T3's Issues feature (#19260, #19270, #19274 and the 19 follow-up rows in [the 4928 appendix](nightly-diff-4928-commits.md), "New feature issues"). T3 source is `~/CandyWrapper-research/t3code` at `v0.1.11-nightly.20261119.4928`. Paths below are relative to it.

## Wire

All schemas live in `packages/contracts/src/issue.ts`. The RPCs are in `packages/contracts/src/rpc.ts:1334-1424`, and every one fails with `IssueUnavailableError` (reason `tool-missing`, `unauthenticated` or `tracker-unsupported`), `IssueOperationError` (`operation`, `detail`, optional `reason` `not-found`, `read-only` or `rate-limited`) or an authorization error.

| Method | Payload | Answer |
|---|---|---|
| `issues.list` | `IssueListInput`: `state` all/open/closed, optional `involvement`, `projectId`, `host`, `limit` 1-200, `cursors`, `refresh`, `query`, `labels`, `assignee`, `sort` updated/created | `IssueListResult`: `viewers`, `trackers`, `entries`, `errors`, `nextCursors`, optional `scopes` |
| `issues.detail` | `IssueRef`: `projectId`, `tracker`, optional `host`, `scope`, `key` | `IssueDetail`: the summary fields plus `writable`, `capabilities`, `viewerPermissions`, `states`, `viewer`, `body`, `reactions`, `comments`, `commentsCursor`, `events`, `linkedPullRequests` |
| `issues.comments` | `IssueRef` plus `cursor` | `{comments, nextCursor}` |
| `issues.linkedThreads` | `ThreadIssueKey`: `tracker`, `host`, `scope`, `key` | `{threads: [{id, projectId, title, archivedAt, settled}]}` |
| `issues.templates` | `IssueScopeRef` | `IssueTemplateList` |
| `issues.candidates` | `IssueScopeRef` | `{labels, assignees, truncated}` |
| `issues.create` | scope plus `title`, `body`, `labels`, `assignees` | `{key, displayKey, url}` |
| `issues.comment` | `IssueRef` plus `body` | void |
| `issues.update` | `IssueRef` plus optional `title`, `body`, whole-set `labels`, `assignees` | void |
| `issues.setState` | `IssueRef` plus `state`, a name from `detail.states` | void |
| `issues.react` | `IssueRef` plus optional `subjectId`, `content`, `reacted` | void |
| `issueTrackers.list` | `{}` | `{trackers: [IssueTrackerConnection], bindings}` |
| `issueTrackers.connect` | `{tracker, token}`, null token disconnects | `IssueTrackerConnection` |
| `issueTrackers.bindProject` | `{projectId, binding}` | void |

Thread side: `ThreadShell.issues` and `AppThread.issues` hold `ThreadIssueLink`s (`orchestrationV2.ts:485`, `:2222`). The commands are `thread.issue.link` (key fields, `projectId`, `url`, `displayKey`, `title`, `source`) and `thread.issue.unlink` (key fields), at `orchestrationV2.ts:3301-3318`. The event `thread.issue-synced` carries the whole thread. `ExecutionEnvironmentCapabilities.issues` (`environment.ts:99`) gates the whole feature and `issueLinkedThreads` (`environment.ts:214`) gates the linked-threads read.

Shapes reuse the pull request ones: `IssueActor` is `PullRequestActor`, `IssueLabel` is `PullRequestLabel` and the reactions are `PullRequestReaction`. CandyWrapper decodes them with the existing Swift types.

## Screens and states

The Issues page is `apps/web/src/components/issue/IssuesPage.tsx`, routed at `/issues` (`routes/_chat.issues.tsx`).

- The header says "Issues", with the right panel toggle, which reads "Select an issue first" until a row is picked (`IssuesPage.tsx:609-640`).
- The toolbar row holds the search (`PullRequestSearchInput`, :658), Sort with Recently updated or Newest, Filters (`IssueListFilterPickers.tsx`: state, involvement, project, labels, assignee), Views (`SavedViewsMenu`, :702), the tracker menu once there is more than one host (:722) and refresh (:731).
- The list body (:475-603) shows one of these states:
  - "Issues unavailable" when no environment has the `issues` capability.
  - The pull request ghost while the first answer loads.
  - The unavailable state with Retry when every read failed.
  - The empty state, "No trackers to read", which is the reference capture.
  - Grouped rows, one section per tracker account.
- A tracker group lists its unconfigured detail, each project's error, "Nothing matches that." or "No issues under these filters." when empty, its rows, and "Load more" per environment that has cursors for its host.
- A warning banner, "<error> Showing the issues that loaded.", sits above a list that partly failed.
- The row is `IssueRow.tsx`: state glyph, `displayKey` in mono, title, assignee avatars and the comment count on the right, and author, tracker icon, scope, server and up to three labels under it.
- The page refreshes on show, on reconnect, and every 5 minutes while visible (`useLiveRefresh`, `hooks/useLiveRefresh.ts:5`). It never refreshes while a list is still loading (:231).
- Mod+backslash, or whatever `rightPanel.toggle` is bound to, toggles the panel (:453, #38309).

The issue panel is `IssueDetailPanel.tsx:379-888`.

- The ghost shows the list row's seed while loading (`IssueDetailGhost.tsx`). A failed first read shows "Could not load this issue" with Retry.
- The title row holds the scope, the key as an external link tinted by state, the state control and the thread link controls (`IssueThreadLinks.tsx`), then refresh.
- The state control is a menu of the other `states` when the viewer may move it, and a plain label otherwise.
- A failed refresh shows the "Could not refresh this issue" alert (#38508, #38537) and keeps the comments already loaded (#39000).
- The title can be edited inline. The meta line reads "author opened 3d ago", then "closed …" and "Read-only".
- Labels and Assignees rows sit under it, each with a candidate picker that reads `issues.candidates` when it opens.
- The Description section can be edited and carries the reaction bar.
- "Linked pull requests" rows open the pull request beside the issue.
- Activity merges comments and events by time. "Load older comments" pages through `issues.comments`, and an empty timeline reads "Nothing has happened here yet."
- A floating comment composer sits at the bottom. It sends on Mod+Enter, and its placeholder is the reason the viewer cannot comment, when there is one.
- `issueWriteAccess` (`packages/client-runtime/src/issuePresentation.ts`) decides every control from `writable`, `capabilities` and `viewerPermissions`.

Thread links come from three places:

- The panel's link button toggles the link for the thread the panel sits beside, or opens a thread picker on the Issues page.
- The "Linked from N threads" count opens the command palette on the issue's URL.
- Thread details rows, the sidebar badge (`components/chat/ThreadDetailsIssueRows.tsx`) and issue links in messages (`lib/openIssueLink.ts`) open the issue in the thread's right panel.

Saved views (`components/SavedViewsMenu.tsx`, `issueSavedViews.ts`, `pullRequestSavedViews.ts`) store named sets of list preferences per kind in local storage. Both pages share them.

T3 4928 has no "start a thread from an issue" action on the web. The agent tools (`link_issue`, `read_issue` and the others) are served by the server's MCP and need no client.

## How it maps onto CandyWrapper

| T3 | CandyWrapper |
|---|---|
| contracts `issue.ts` | `T3Protocol/Domain/Issues.swift`, new |
| `issues` capability | `PullRequestCapabilities.has(env, "issues")` in the app, which reads the descriptor |
| `PullRequestSearchInput`, compact sort menu, filter option icons | the same controls `PullRequestsPageView` builds: `InputGroupView`, outline `ButtonView` menu triggers, `CountPill` |
| `PullRequestListGhost`, `PullRequestsUnavailableState`, `Empty` | `PullRequestListGhostView` and the page's body states |
| `IssueRow` in the pull request row's shape | `IssueRowView`, laid out on `PullRequestRowView`'s metrics with `PullRequestAvatarView` and `PullRequestLabelChip` |
| `issueList.ts` hold, continue, group, filter scopes | `Features/Issues/IssueListLogic.swift` |
| `issuePresentation` state tones | `PullRequestStyle.color` tones: open green, completed violet, not-planned grey |
| `IssueDetailPanel` sections, meta rows, reaction bar, markdown, candidate picker | `SectionItem`, `MetaRowsItem` shapes, `PullRequestReactionBarView`, `PullRequestCandidatePickerView` and the markdown views from Features/PullRequests |
| right panel `issue` surface | the page's own right panel, as `PullRequestsPageContainer` holds the pull request panel |
| `SavedViewsMenu` | `Features/Issues/SavedViewsMenu.swift`, used by both pages |

## Not in this pass

- Issue tracker settings (`IssueTrackerSettings.tsx`): connecting Linear and binding projects through `issueTrackers.*`. The wire types are decoded but the page is left.
- Creating issues and reading templates (`issues.create`, `issues.templates`). No 4928 web surface calls either, so CandyWrapper has nothing to copy.
- Hover preview cards for issue links in messages (#38294) and opening Linear links in messages in the panel (#38854).
- Dictation in the comment composer. CandyWrapper has no voice input.
- Thread details issue rows. Features/Thread belongs to another agent today.
