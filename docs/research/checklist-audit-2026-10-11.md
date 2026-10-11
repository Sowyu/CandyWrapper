# Parity checklist audit

Audited 2026-10-11 against `App/Sources`, `Packages/CandyKit/Sources` and `PROGRESS.md`. Rows are the checklist line numbers in `docs/parity-checklist.md`. Verdicts: built, partly built, not built, milestone 9, not applicable, in progress (another agent is building it now).

## Counts

- built: 13
- partly built: 87
- not built: 118
- milestone 9: 12
- not applicable: 12
- in progress: 20
- total audited: 262

## Sidebar

| Row | Line | Verdict | Evidence or missing part |
|---|---|---|---|
| Sidebar header: wordmark, back/forward, new thread, search | 32 | not built | No history back/forward buttons or navigation stack in Features/Sidebar or App. Header has wordmark, new thread and search only. |
| Project list grouped by project, collapsible project rows | 33 | not applicable | Collapsible project rows exist only in LegacySidebar.tsx. The current sidebar filters by project through the scope popup (`SidebarProjectScopeView`). |
| Project grouping and order (settings: Project grouping, Project order) | 34 | partly built | `SidebarModel.buildProjectGroups` groups by repository; the order setting drives the scope popup (`GeneralSettingsView`). Grouping setting is stored only. |
| Project favicon / monogram / custom icon with color | 36 | partly built | Favicon and monogram in `Features/Sidebar/ProjectIcons.swift`. Icon picker dialog missing (buttons disabled in `ProjectSettingsView`). |
| Project row menu (new thread, rename, project settings, remove, copy path, open in editor) | 38 | partly built | Row menu is LegacySidebar-only. The scope popup settings button (`SidebarProjectScopeView.onSettings`) calls `actions.openProjectSettings`, which no App code sets. Unwired. |
| Threads without a project ("No project" group, scratch folder) | 39 | not built | No scratch project, no "No project" group, no `mod+alt+n`. `SidebarListModel` carries a ponytail note for the scratch machine label. |
| Section: Working (beta, folds running/monitoring threads) | 42 | not built | Setting "Working section" is stored (`GeneralSettingsView`); no shelf in `SidebarListModel`. |
| Thread hover card (summary, PR, branch) | 48 | not built | No ThreadHoverCard. Only the PR badge mini list (`ThreadPullRequestsMiniListView`) exists. |
| Thread row actions: settle, wake, unpin, discard, snooze | 49 | built | `SidebarCommands.settle/unsettle/snooze/pin/unpin` behind the row buttons (`RowActionButton` in `SidebarRowViews`). Stale mark. |
| Thread context menu: Pin, Settle, Snooze (presets and Custom...), Archive, Delete, Rename, Regenerate title, Copy path,  | 50 | partly built | `ThreadActionMenu.items` plus `SidebarCommands.showThreadMenu/perform`: pin, settle, snooze presets, archive, regenerate title, mark unread, copy path/branch/ID, auto-settle. Missing (`SidebarCommands.unbuiltMenuItems`): rename, delete, custom snooze, new thread on branch, project settings. |
| Custom snooze dialog (date/time or duration) | 51 | not built | Listed in `unbuiltMenuItems` as `snooze:custom`; no dialog. |
| Multi-select threads (cmd/shift click) with bulk actions | 52 | not built | No selection store in the sidebar. |
| Inline thread rename | 53 | not built | No inline rename; `rename` is in `unbuiltMenuItems`. |
| Drag and drop reorder within and between sections with action badge (Pin, Unpin, Settle, Un-settle, Wake) | 54 | not built | No drag reordering or drop badge in `SidebarListView`/`SidebarRowViews`. |
| Drag thread onto composer to attach as context | 55 | not built | No drag source on rows. |
| Drop files onto thread row to attach in its composer | 56 | not built | Only `ComposerView` registers for dragged types. Rows accept no drops. |
| Undo notice at bottom of sidebar (5 s, `thread.undo`) | 57 | built | `SidebarUndoNoticeView`, `SidebarCommands.showUndo`, `thread.undo` shortcut. Stale mark. |
| Thread relationships (fork, subagent, handoff) icons and navigation | 59 | not built | Lineage is decoded (`ThreadProjection.lineage`) but no relationship icon or control. |
| Sidebar footer: settings entry, usage entry, connection status | 60 | built | Settings, Pull Requests and Usage buttons in `SidebarContentView`. The official Sidebar.tsx does not draw a connection status dot. The Usage page behind the button is in progress. |
| Desktop update pill and release notes in sidebar | 61 | milestone 9 | Update pill needs the auto-updater. |
| Provider update pill in sidebar | 62 | not built | No provider update pill; provider update checks are not read anywhere in the sidebar. |
| T3 Connect sign-in in sidebar | 63 | built | T3 puts it in the settings sidebar footer. Built in `T3ConnectSignInView` and `T3ConnectController` (native Clerk, email code and password). Stale mark. |
| Settled/auto-settle rules (merged PR, 3 days inactive, closed PR) | 65 | built | Server-owned. The Settled shelf and sections display it (`SidebarListModel`); auto-settle settings in `GeneralSettingsView`. |
| Limited-thread recovery in sidebar (Resume at reset, Snooze until reset, Wake now) | 66 | not built | No Resume at reset, Snooze until reset or Wake now actions in the sidebar. |
| Legacy sidebar (opt-in setting) | 67 | not built | LegacySidebar.tsx is a separate 3,800 line component. Needs a decision whether to build it at all. |
| Empty states: no projects hero, no active thread | 68 | partly built | Text-only empty state. `SidebarListModel` notes the missing "Add project" button; no-projects hero missing. |
| Legacy thread migration toast | 69 | not built | No migration toast. Low priority, depends on a server that holds legacy threads. |

## Thread view

| Row | Line | Verdict | Evidence or missing part |
|---|---|---|---|
| Chat canvas layout, chat width setting (comfortable, wide, full) | 75 | not built | Chat width setting is stored (`AppearanceSettingsView`); `TimelineView` uses fixed lane width. |
| Thread header: breadcrumb (project > thread), editable title, thread actions menu | 76 | partly built | `ThreadHeaderView` draws project / title. No editable title, no thread actions menu. |
| Header controls: Open in editor picker, git actions, project scripts, panel layout toggles | 77 | partly built | Details toggle and panel toggles in `ThreadHeaderView`; git actions in `ThreadDetailsCardView`. No editor picker, no project scripts control. |
| Thread details panel/card (PR rows, branch, worktree, runtime, automations) | 78 | partly built | `ThreadDetailsCardView` has workspace, version control and PR rows. Missing: inline placement, Open in, scripts, PR second line, automations, lineage, compact densities. |
| Thread status line (running, elapsed, agent activity) | 79 | partly built | `WorkingRowView` shows "Working for Ns". No agent activity text. |
| Timeline: user message bubble (text, chips, image shelf, file chips) | 80 | partly built | Image grid and file rows in `TimelineMessageRows`. Missing: chips in text, file preview and download, video. |
| Timeline: V2 item inspector (raw item detail) | 90 | partly built | `WorkDetailView` shows item detail. No rich blocks or Open diff. |
| Timeline: worktree setup card (progress of setup script) | 91 | not built | No worktree setup card row kind. |
| Timeline: secret request card | 92 | partly built | `EventRowView` shows a title row for `.secretRequest`. No secret entry form. |
| Timeline: HTML render frame (visual replies) | 93 | not built | Needs webview, ask user first. Not started. |
| Timeline: MCP app frame (MCP Apps standard) | 94 | not built | Needs webview, ask user first. Not started. |
| Timeline: subagent items and bar | 95 | partly built | Subagent items render as event cards (`EventRowView`). No follow-along bar. |
| Provider status banner (not installed, not signed in, outdated) | 98 | not built | No provider status banner among composer banners (`ComposerBannerView` users are environment and error banners). |
| Markdown: Mermaid diagrams | 102 | not built | Needs webview, ask user first. No Mermaid code. |
| Markdown: images and image gallery, zoomable image, expanded image dialog | 103 | partly built | `MarkdownLayout` .image reserves a 16:9 loading slot. No loading, gallery or zoom. |
| Markdown: video/audio attachments and media actions | 104 | partly built | AVKit used in `FileSurfaceView` for file tabs. No media in markdown or attachments. |
| Markdown: file links (path:line) open in file panel; external links open in browser | 105 | partly built | File links open the panel, web links hit tested (`MarkdownLinkHitView`). Missing: Cmd-click to editor, chip menu Open and Reveal, link favicons. |
| Markdown: assistant citation chips with comments | 107 | not built | No citation chip code. |
| Markdown: skill inline text, shell command block | 108 | not built | No skill text or shell command block in markdown. |
| Quote an assistant response / selection toolbar | 110 | not built | No selection toolbar. |
| Tool card: file change (path list, +/- counts, inline diff) | 112 | partly built | `ChangedFilesCardView` and work rows show paths and counts. No inline diff. |
| Tool card: todo list | 114 | not built | Todo items are decoded in `TurnItem` only. No card or tasks badge. |
| Plan mode: proposed plan with follow-up banner (Implement / refine) | 120 | partly built | `PlanRowView` draws the proposed plan card with Expand plan. No follow-up banner (Implement or refine) and no plan actions menu. |
| Permission update notice | 122 | not built | No permission update notice. |
| Resume button in empty composer (limited or interrupted turn) | 126 | partly built | `ComposerLogic` resume face and "Resume thread" tooltip. Usage-limit failures do not resume (ponytail at ComposerLogic.swift:169). |
| Usage limit recovery banner (auto-resume, snooze until reset) | 127 | not built | `ComposerFeedback` hides the error banner for usage limits but nothing replaces it. Needs the limits data from the Usage work. |
| Goal row above composer (`/goal`) | 128 | not built | Goal status is read for the sidebar (`SidebarListModel`) only. No row above the composer. |
| Timeline minimap | 130 | not built | No minimap. |
| Find in thread bar (`chat.find`) with highlights and next/prev | 132 | not built | No find bar in the thread view. |
| Edit an earlier prompt and rerun / fork | 133 | not built | No edit-and-rerun on user messages. |
| Fork thread, merge back, handoff to worktree | 134 | not built | Fork, merge back and handoff exist only as MCP tool labels (`T3McpTools`). No UI. |
| Restart agent session | 135 | not built | No restart-session command. |
| Activity log | 136 | built | Fold summaries ("Ran 2 commands...") in `T3Store/WorkLog.swift`, `WorkLogText.swift`, `T3McpTools.swift`. The doc describes exactly this. Open diff belongs to row 88. |
| Context window meter | 137 | not built | No context window meter in the composer. |
| Thread automations panel (scheduled tasks, PR watch) | 138 | in progress | Thread automations panel belongs to the Scheduled tasks work. |
| Drag files onto thread to attach | 141 | not built | Composer registers for drags; the thread canvas does not. |

## Composer

| Row | Line | Verdict | Evidence or missing part |
|---|---|---|---|
| Composer surface: rich text editor (bold, italic, code, lists, blockquote, headings, hr, task list) | 147 | not built | Setting stored; composer is a plain text editor (`ComposerEditor`). |
| Fenced code block node with language picker | 148 | not built | No fenced block node. |
| List continuation and splitting, undo grouping | 149 | not built | No list continuation. |
| Pull request picker (`#`) | 155 | partly built | `PullRequestCandidatePickerView` lists the repository PRs. No `pullRequests.detail` lookup outside the listed 99. |
| Inline context chips: terminal excerpt, review comment, preview annotation, file, PR, thread, image | 156 | partly built | File, folder, skill, thread, PR and attachment chips (`ComposerChips`). Missing terminal, review comment and preview annotation chips. |
| Attached file preview panel | 160 | not built | Only the image preview exists (`ExpandedImagePreviewView`). |
| SnapShot attachment details | 161 | not built | No SnapShot attachments. |
| Model picker (providers sidebar, search, favorites, multi-select with shift-click) | 162 | partly built | `ModelPickerView` has search, favorites and provider keys. No shift-click multi-select. |
| Custom models editor | 164 | partly built | Settings can add and remove custom models (`ProvidersSettingsView`). No composer editor. |
| Worktree base branch picker | 170 | in progress | Used by Scheduled tasks settings only; `BranchPickerView` is ready. |
| Composer banners stack (clone progress, server update, provider issues) | 173 | partly built | Only the environment reconnecting banner (`EnvironmentBannerView`). No clone progress, server update or provider issue banners. |
| Composer usage limits chip | 175 | in progress | Built with the Usage page. |
| Collapse composer on scroll (setting) | 179 | not built | Setting stored; no collapse behavior. |
| Pending terminal contexts | 180 | not built | No pending terminal context. |
| Voice input | 182 | not applicable | Voice input is iPhone only per the official docs. |
| Start in background (`mod+enter` new thread, `mod+alt+enter`) and send-and-new-thread | 183 | partly built | `ComposerLogic` resolves `composer.sendBackground` and `sendAndNewThread`; `ComposerView` sends in the foreground (ponytail at ComposerView.swift:453). |
| Multi-model fan-out (shift-click models, one thread and worktree each) | 184 | not built | No fan-out. No multi-select models. |

## Right panels

| Row | Line | Verdict | Evidence or missing part |
|---|---|---|---|
| Right panel container, tab strip, new tab (+) menu, close (`mod+w`), reopen closed (`mod+shift+t`) | 191 | partly built | `RightPanelState` store and tab strip. No resize handle, no strip scroll buttons, Terminal and Device launcher entries disabled. |
| Right panel resize handle, sheet mode on narrow windows | 192 | not built | ponytail in `RightPanelView`: no resize handle; no sheet mode. |
| Diff panel (`diff.toggle`): turn selector, file tree, unified/split, wrap, whitespace toggle | 193 | partly built | `DiffPanelView` has turn scope, split/unified, wrap, whitespace. File tree aside is inert (ponytail at DiffPanelView.swift:93). |
| Diff file tree with status icons | 194 | not built | Same ponytail: tree aside not built. |
| Diff code view: syntax highlight, collapsed unchanged ranges, folded files | 195 | partly built | Syntax highlight and "n unmodified lines" row (`DiffRowViews`). Hidden lines cannot be expanded. |
| Diff inline review comments (annotate, submit, add to chat as chip) | 196 | not built | `DiffListView.annotations` exists and the PR Code tab uses it. The thread diff has no annotate, submit or chip flow. |
| Diff find (`mod+f`, not configurable) | 197 | not built | No find in the diff. |
| Diff copy path, open in editor, revert file actions | 198 | not built | No copy path, open in editor or revert file actions on diff files. |
| Settings: diff colors, layout, whitespace, default file state | 199 | partly built | Layout, wrap and whitespace read from settings (`DiffPanelView`). Diff colors stored only. |
| File comments (review annotations in files) | 204 | not built | No file comments in `Features/Files`. |
| Browser/preview panel: URL bar, tabs, back/forward/reload, zoom, favicon, incognito | 207 | partly built | Server tabs only, chrome row, loading bar, address bar. No desktop tabs, zoom UI beyond shortcuts, incognito. |
| Browser: pick element and annotate (adds chip to composer) | 210 | not applicable | T3 itself does not offer this for streamed server tabs; CandyWrapper has no desktop tabs. |
| Browser: agent control via CDP (click, type, screenshot, recording) | 211 | built | Agents drive the server browser; the app views and steers (`ServerBrowserView`). Screenshot and recording buttons are desktop-tab only in T3. |
| Browser: floating mini player (PiP) | 212 | partly built | `BrowserMiniPlayerView`. Missing resize handles. |
| Browser: import sessions from other browsers | 214 | not applicable | Imports cookies into Electron desktop tabs. CandyWrapper has no desktop tabs. |
| Device panel (iOS Simulator / Android Emulator stream, tabs, rename) | 216 | not built | No device code outside the Integrations settings rows. Panel needs a transport check first; row 216 may need SceneKit or a webview for the 3D view. |
| Device setup flow (hub install, platform check, agent access) | 217 | not built | No device code outside the Integrations settings rows. Panel needs a transport check first; row 216 may need SceneKit or a webview for the 3D view. |
| Device controls rail (home, back, recents, rotate, power, fold, 3D view) | 218 | not built | No device code outside the Integrations settings rows. Panel needs a transport check first; row 216 may need SceneKit or a webview for the 3D view. |
| Device tools drawer (appearance, text size, location, permissions, push) | 219 | not built | No device code outside the Integrations settings rows. Panel needs a transport check first; row 216 may need SceneKit or a webview for the 3D view. |
| Device touch input and floating device window | 220 | not built | No device code outside the Integrations settings rows. Panel needs a transport check first; row 216 may need SceneKit or a webview for the 3D view. |
| Terminal tab in right panel | 222 | not built | Launcher entry "Terminal" is disabled (`SurfaceLauncherView.actions`); terminal only lives in the drawer. |

## Git and pull requests

| Row | Line | Verdict | Evidence or missing part |
|---|---|---|---|
| Publish repository (public/private, provider choice) | 230 | partly built | `PublishRepositoryDialog` three-step wizard, never run against a host. Missing header layout/tint, two glyphs, Source Control link. |
| Create pull request / change request | 231 | partly built | `GitActionsLogic` runs `create_pr` through `git.runStackedAction`; `PullRequestComposerView`. Never run against a real host. |
| PR stack actions (GitHub stacks) | 232 | partly built | Stack header, menu and layers built (`PullRequestStackViews`). Never run against a real host. |
| Worktrees: create, reuse, list, cleanup, handoff | 245 | partly built | New worktree mode on drafts (`BranchToolbarLogic.EnvMode`), server creates it. No list, cleanup UI or handoff. |
| Clone project with progress toast and retry | 246 | not built | No clone flow. Add project runs the folder picker only (`SidebarCommands.addProject`). |
| Source control provider cards (auth status, rescan) | 247 | built | `SourceControlSettingsView` has provider cards with auth status and rescan. Stale mark. |

## Terminal

| Row | Line | Verdict | Evidence or missing part |
|---|---|---|---|
| Terminal tabs and split groups (max 4 per group), horizontal/vertical splits | 254 | partly built | `TerminalDrawerView` shows one terminal; split buttons open the next `term-N` (ponytail at TerminalController.swift:194). No list aside or split grid. |
| Add terminal selection to chat as context chip | 257 | not built | Terminal context menu lacks Add to chat; no terminal chip. |
| Project scripts / actions run in terminal (script. commands, `runOnSettle`) | 260 | not built | Actions are stored (`ProjectActionsLogic`) but never run. No `script.<id>.run` handler, no scripts control in the header. |
| Provider auth terminal (sign-in helper) | 261 | not built | No provider auth terminal. |
| Idle terminals close on settle | 262 | not applicable | Server side; the client does nothing. |

## Settings

| Row | Line | Verdict | Evidence or missing part |
|---|---|---|---|
| Settings breadcrumb, group and row layout, scope notice | 273 | built | `SettingsScopeNoticeView` in `ScopedSettingsPage.swift`, used by `ProjectSettingsView`/`StorageSettingsView`. Stale mark. |
| Project overview (name, path, repo identity, icon, favicon) | 281 | partly built | Rename and reset icon (`ProjectSettingsView`). Icon and image file pickers disabled. |
| Actions (scripts): add, edit, run on settle, keybinding | 285 | partly built | Action list, editor and shortcuts (`ProjectActionEditor`, `ProjectActionsLogic`). Running is missing, t3.json import missing. |
| Webhook automations | 287 | in progress | Part of the Scheduled tasks work. |
| Update track (stable / nightly) and update status/download/install | 294 | milestone 9 | Rows shown without actions (`GeneralSettingsView`). Needs the updater. |
| Thread notifications (Off, Notifications, Sound only, Notifications with sound) | 295 | partly built | Mode stored; no alerts. Delivery is the notifications package. |
| In-app notifications toggle | 296 | partly built | Stored; no in-app toasts for thread events. |
| Proactive panels | 300 | partly built | Stored; auto-open not built. |
| Rich text composer; Collapse composer on scroll | 302 | partly built | Stored. Rich text composer and collapse on scroll not built (rows 145, 177). |
| Organization: Project grouping, Project order | 307 | partly built | Order works, grouping stored only. |
| Organization: Working section (beta) | 309 | partly built | Stored; shelf not built (row 40). |
| Projects and threads: New threads defaults, Submodules, Start from origin, Add project starts in | 311 | partly built | Rows wired (`GeneralSettingsView`, `ComposerController`). Traits picker missing. |
| Confirmations: Unpin, Archive, Delete, Quit shortcut (Hold, Direct, Double press) | 312 | partly built | Stored; prompts for unpin, archive, delete and the quit hold not built. |
| Text generation model | 313 | partly built | Model picker writes the setting; traits picker missing. |
| `t3` CLI command install row | 314 | milestone 9 | CLI install row; CandyWrapper installs no CLI (skipped by design). |
| About: version, privacy policy, telemetry note, Diagnostics link, Open source licenses | 315 | partly built | Version and privacy policy built. Licenses page missing (ponytail at GeneralSettingsView.swift:384). |
| Legacy toggles: Plan mode, Context window indicator, Sidebar | 316 | partly built | Plan mode wired; context window indicator and sidebar toggle stored only. |
| Theme gallery with previews, separate light and dark themes | 324 | not built | ponytail at AppearanceSettingsView.swift:8: no theme gallery. |
| Theme search (OpenVSX) and VS Code theme import | 325 | not built | No theme search or import. |
| Theme editor (pick area, color picker, advanced colors, export JSON) | 326 | not built | No theme editor. `themeEditor.toggle` keybinding is not handled. |
| Environment-published themes (Duplicate) | 327 | not built | No environment-published themes. |
| Contrast; Glass opacity | 328 | partly built | Sliders store; no effect. |
| Diff colors; Chat width; Composer context | 329 | partly built | Diff colors, chat width and composer context are stored; no behavior. |
| Environment identification (color/label per env) | 330 | partly built | Stored; the sidebar and chrome do not draw environment colors or labels. |
| Panel animations slider 0-400 ms | 331 | partly built | Slider stores; nothing animates by it. |
| Fonts: Interface, Prompt, Code, Terminal; font smoothing; word wrap; advanced typography | 332 | partly built | Family and size stored (ponytail at AppearanceSettingsView.swift:140); text styles ignore them. |
| Open keybindings.json; config warnings and update toasts | 340 | partly built | Opens the file. No config warnings or update toasts. |
| Enable toggle and setup dialog (screen recording, accessibility, shortcut) | 346 | partly built | Page and switch stored. No capture, permissions or setup dialog. |
| Include app text; Capture shortcut recorder; sound; flash; animations | 347 | partly built | Rows store values; shortcut recorder read-only. |
| Add provider instance wizard (driver choice, ACP registry search, auth step) | 354 | not built | Both entry points drawn disabled (`ProvidersSettingsView`). |
| Provider status (installed, version, auth, update available) and Update now | 355 | partly built | Summaries, versions and refresh. No advisory popover or Update now. |
| Provider config form (binary path, home dir, env vars with redaction, args) | 356 | partly built | Text fields per driver. No env var editor, Antigravity or ACP fields, accent color. |
| Provider sign-in terminal and auth callback | 357 | not built | No auth terminal or OAuth callback. |
| Models list, custom models, accent color | 358 | partly built | Grouped list, favorites, custom models. Hidden models and order stored only; no custom model editor, accent color. |
| Codex setup, add Codex account, ChatGPT account/sharing/usage | 359 | not built | Not built. |
| ACP session management section | 360 | not built | Not built. |
| Usage providers (incl. Cursor account usage via Keychain) | 361 | in progress | Part of the Usage work. |
| Provider update notifications (launch and primary) | 363 | not built | Not built. |
| Devices: device hub toggle, agent device access, simulator support, device hosts (SSH) | 369 | partly built | Hub and agent access rows show values. Missing `device.configure`, simulator status, device hosts. |
| Browser: profiles, default profile, viewport, zoom, appearance | 370 | partly built | Viewport, zoom, appearance store. Profiles and presets missing. |
| Browser: recording frame rate, show key presses, show mouse presses | 371 | partly built | Stored; the browser does not read them. |
| Browser: Open links in, Auto-show floating preview | 372 | partly built | Stored; Open links in and Auto-show floating preview not honoured. |
| MCP / outside agents (listed under Connections) | 373 | partly built | Copy MCP URL only (see row 407). |
| GitHub accounts and token; per-host routing | 385 | partly built | Token per host. Accounts and routing need `gh`. |
| Bitbucket credentials | 386 | not built | Not built. |
| Writing style (Repository conventions, Conventional Commits, Custom), writer model, follow templates | 389 | partly built | Style select, templates, writer model. Missing "Write custom instructions for all" and traits picker. |
| Default merge method; Remove agent credits when merging | 390 | partly built | Rows stored; the merge tab does not start from them. |
| This machine: environment name, icon, version, update | 404 | partly built | Name, icon, version (`ConnectionsSettingsView`). Update actions and row menu missing; update is M9 work. |
| Environments list (add backend, SSH, remote link, route, remove, reconnect status) | 405 | partly built | Add by pairing link, reconnect, remove. No SSH, route reorder, permissions panel only partly (`PermissionsDisclosureRow` exists). |
| Network access toggle; Tailscale HTTPS; pairing link with QR | 406 | partly built | Toggles show state but stay disabled (bridge-only, `SettingsController.bridgeTooltip`). Pairing link with QR is built (`PairingLinkRowView`). |
| Authorized clients list, revoke one/others | 407 | built | `AuthorizedClientsSectionView`, `ClientSessionRowView`, revoke and revoke others. Stale mark. |
| T3 Connect toggle, Publish agent activity, Hold webhooks while offline | 408 | partly built | Publish agent activity and Hold webhooks built (`SettingsHostAccess`). The T3 Connect link switch is disabled (linking left to T3 Code). |
| Outside agents: MCP URL copy, approve sign-in | 409 | partly built | Copy MCP URL in the environment menu. No sign-in approval. |
| Load balancing (Prefer, Normal, Less often, Manual only) | 410 | not built | Only in the settings search catalog. |
| GitHub sharing (Read PRs / Read and act) | 411 | not built | Only in the settings search catalog. |
| WSL backend | 412 | not applicable | Windows only. |
| Resource history charts (5m, 15m, 30m, 1h) | 426 | partly built | Window selector, stats, CPU bars, top processes. Missing telemetry stream, tooltips. |
| Trace diagnostics (latest failures, common failures, slowest spans, span logs, top names) | 427 | partly built | Stats and five tables. Missing open logs folder, copy trace id, expandable text. |

## Command palette

| Row | Line | Verdict | Evidence or missing part |
|---|---|---|---|
| Search groups: Projects, Threads (title and message search, 2+ chars), Settings | 437 | partly built | Projects and Threads built (`PaletteCommands`). Settings group missing though `SettingsSearch` now exists. |
| New thread in... (project chooser incl. No project) | 438 | partly built | `new-thread-in:` pages built. No "No project". |
| New thread without a project | 439 | not built | Needs scratch projects (row 37). |
| Find in current thread | 440 | not built | No find in thread. |
| Restart agent session | 442 | not built | No restart session action. |
| New project (name, optional private GitHub repo) | 445 | not built | No new project flow. |
| Add project: local folder browser (directories list with ".."), clone from provider or URL, existing project | 446 | partly built | Folder picker only. No browser, clone or environment step. |
| Open WSL folder | 447 | not applicable | Windows only. |
| Change theme (sub-page with live preview) | 448 | not built | No theme sub-page. |
| Toggle theme editor | 450 | not built | No theme editor. |
| Open pull requests; Open usage; Open settings; Project settings | 451 | partly built | Pull requests, settings built; Usage opens a page being built; Project settings not wired. |
| Environment picker inside multi-env flows | 452 | not built | No environment step in add-project or new-thread flows. |
| Command palette bus (open to a given page from elsewhere) | 453 | partly built | `chat.new` opens the project page; the sidebar new-thread button creates directly. |
| Thread find/search within palette using server `thread.find` | 455 | partly built | Message search built; match line is plain text. |

## Keyboard shortcuts

| Row | Line | Verdict | Evidence or missing part |
|---|---|---|---|
| composer.cycleHost | 526 | not built | `composer.cycleHost` has no handler. |
| Fixed, not configurable: diff find | 528 | not built | No diff find. |

## Notifications and dock badge

| Row | Line | Verdict | Evidence or missing part |
|---|---|---|---|
| Notification coordinator: events when a thread finishes, fails, or needs approval/input | 539 | not built | No UNUserNotificationCenter, sound or dock badge code anywhere. |
| Modes: Off, Notifications, Sound only, Notifications with sound | 540 | not built | No UNUserNotificationCenter, sound or dock badge code anywhere. |
| System notification (click focuses the thread) | 541 | not built | No UNUserNotificationCenter, sound or dock badge code anywhere. |
| Notification sound, audio unlock | 542 | not built | No UNUserNotificationCenter, sound or dock badge code anywhere. |
| Dock badge count of threads with unread notifications; cleared on window focus | 543 | not built | No UNUserNotificationCenter, sound or dock badge code anywhere. |
| In-app toasts (toast manager, anchored copy toast, undo toasts) | 544 | partly built | `ToastQueue`, `ToastViewport` and the undo notice exist. No anchored copy toast seen. |
| Slow RPC toast, keybinding update toast, provider update toast | 545 | not built | No slow RPC, keybinding update or provider update toasts. |
| Mobile push / Live Activities for agent activity | 546 | not applicable | Server publishes; no macOS client work. |

## Onboarding and welcome

| Row | Line | Verdict | Evidence or missing part |
|---|---|---|---|
| First-run gate (decides wizard vs app; Still connecting; Could not read settings) | 552 | not built | No onboarding code. Only pairing helpers in `T3Client/Pairing.swift`. |
| Welcome wizard step 1: connect computers (T3 Connect list, add a computer by pairing link) | 553 | not built | No onboarding code. Only pairing helpers in `T3Client/Pairing.swift`. |
| Welcome wizard step 2: check agents (Claude Code, Codex install/sign-in via terminal) | 554 | not built | No onboarding code. Only pairing helpers in `T3Client/Pairing.swift`. |
| Welcome wizard step 3: import projects (scan, groups, select all/none, conversation import) | 555 | not built | No onboarding code. Only pairing helpers in `T3Client/Pairing.swift`. |
| Wizard progress bar and navigation | 556 | not built | No onboarding code. Only pairing helpers in `T3Client/Pairing.swift`. |
| Connect onboarding dialog | 557 | not built | No onboarding code. Only pairing helpers in `T3Client/Pairing.swift`. |
| Permission checklist (macOS permissions) | 558 | not built | No onboarding code. Only pairing helpers in `T3Client/Pairing.swift`. |
| Pairing route (`/pair`) | 559 | not built | No onboarding code. Only pairing helpers in `T3Client/Pairing.swift`. |
| Connect CLI auth and connect-agent surfaces | 560 | not built | No onboarding code. Only pairing helpers in `T3Client/Pairing.swift`. |
| Nightly mobile beta promo | 561 | not built | Optional promo. |

## Remote environments and T3 Connect

| Row | Line | Verdict | Evidence or missing part |
|---|---|---|---|
| Desktop-managed SSH environments (password prompt dialog) | 569 | not built | No SSH environments. |
| T3 Connect: sign in (Clerk), cloud environments list, connect/remove | 570 | built | `T3ConnectController`, `T3ConnectAccountView`, `T3ConnectSignInView`, `T3Client/Connect/`. Live with the user's account. Stale mark. |
| T3 Connect relay client install dialog | 571 | not built | Skipped in WP6.4 because the app hosts no relay client. Needs a decision. |
| Account profile pages (user, mobile clients) | 572 | partly built | Account menu and `T3ConnectAccountView` built. Mobile clients page skipped. |
| Electron-managed auth shell (browser handoff, passkeys) | 573 | partly built | Native Clerk sheet (email code and password). Social buttons and passkeys left out. |
| Environment connection status dots, reconnecting reasons | 574 | built | Dot, status text and tooltip per environment (`ConnectionsSettingsView.Dot`), reconnect banner (`EnvironmentBannerView`). Stale mark. |
| Version skew blocking (app newer than server and vice versa) | 576 | partly built | Protocol mismatch shows "Client not supported". No skew blocking flow. |
| Remote server update (self-update progress, desktop-managed update) | 577 | not built | No server update action. |
| Load balancing of new threads across machines | 578 | not built | See row 408. |
| Outside agents (Claude Code, Codex, ChatGPT connect via MCP URL + OAuth approval) | 579 | not built | See row 407. |
| Background service (`t3 service`) | 581 | not applicable | CLI, not a UI feature. |
| Threads from older versions (migration) | 582 | not built | No migration flow. Low priority. |

## Usage and limits

| Row | Line | Verdict | Evidence or missing part |
|---|---|---|---|
| Usage page route and shell, environment dropdown, refresh | 588 | in progress | Usage page is being built by another agent. |
| Tabs: Cost, Tokens, Limits (keys c, t, l) and period (day, week, month, quarter) | 589 | in progress | Usage page is being built by another agent. |
| Charts by provider/model, token-type split, cache savings, premium/other cost | 590 | in progress | Usage page is being built by another agent. |
| Model breakdown detail dialog | 591 | in progress | Usage page is being built by another agent. |
| Custom model prices and aliases | 592 | in progress | Usage page is being built by another agent. |
| Limits: pooled subscription windows per provider, per-account segments, reset times, Use reset | 593 | in progress | Usage page is being built by another agent. |
| Limit sources: add CLIProxyAPI hub | 594 | in progress | Usage page is being built by another agent. |
| Subscription usage widget (composer / header) | 595 | in progress | Usage page is being built by another agent. |
| `/usage-limits` slash command result above composer | 596 | in progress | Usage page is being built by another agent. |
| Enable Cursor usage (Keychain) | 597 | in progress | Usage page is being built by another agent. |

## Scheduled tasks

| Row | Line | Verdict | Evidence or missing part |
|---|---|---|---|
| Settings page: per-environment task list with enable switch, Run now, Delete | 603 | in progress | Scheduled tasks are being built by another agent. |
| Task editor (title, prompt, project, model, schedule: cron/interval/once, mode) | 604 | in progress | Scheduled tasks are being built by another agent. |
| Webhook triggers: URL, rotate token, delivery history (headers, query, body) | 605 | in progress | Scheduled tasks are being built by another agent. |
| Thread automations panel (tasks tied to a thread) | 606 | in progress | Scheduled tasks are being built by another agent. |
| Pull request watch (agent wakes on PR activity) | 607 | in progress | Scheduled tasks are being built by another agent. |

## Devices and SnapShot

| Row | Line | Verdict | Evidence or missing part |
|---|---|---|---|
| Device panel (see Right panels) | 613 | not built | Same as rows 214 to 218. |
| Device hosts over SSH, tool updates | 614 | not built | Not built. |
| SnapShot capture: global shortcut (both Shift keys by default), active window capture, attach to draft | 615 | not built | No ScreenCaptureKit code. |
| SnapShot coordinator in renderer (attach, pending captures on disk) | 616 | not built | Not built. |
| SnapShot capture feedback (sound, flash, animation) | 617 | not built | `SnapShotSettingsView` rows only. |

## Desktop-only

| Row | Line | Verdict | Evidence or missing part |
|---|---|---|---|
| App menu: Check for Updates... | 628 | milestone 9 | Needs the updater. |
| App menu: Quit T3 Code (Cmd+Q, hold-to-quit logic) | 632 | not built | Quit uses `NSApplication.terminate`. No hold-to-quit (setting stored, GeneralSettingsView.swift:345). |
| File menu: Close (Cmd+W) | 633 | not built | No File menu in `AppDelegate`. |
| View menu: Reload (Cmd+R), Force Reload (Shift+Cmd+R), Toggle Developer Tools (Alt+Cmd+I) | 635 | not applicable | Reload and developer tools need a web inspector. No equivalent. |
| View menu: Actual Size (Cmd+0), Zoom In (Cmd+=, Cmd+Plus), Zoom Out (Cmd+-), Toggle Full Screen | 636 | not built | No View menu, full screen or zoom items. |
| Help menu: Check for Updates... | 638 | milestone 9 | Needs the updater. |
| Context menus (native menu for items, fallback in web) | 639 | partly built | NSMenu used for thread menus, file chips, popups. Several right-click targets still have none. |
| Window vibrancy / glass opacity | 648 | not built | Glass opacity slider stores only; window has no vibrancy parameters from the setting. |
| Running-thread keep alive (prevent App Nap / sleep while agents run) | 650 | not built | No `beginActivity` call. |
| Single instance; second launch focuses existing window | 651 | not built | No single-instance handling. |
| App activation coordination (focus thread on notification click) | 652 | not built | Needs notifications first. |
| Native theme sync (window appearance follows chosen mode) | 653 | built | `PaletteCommands` sets `NSApp.appearance` for System, Light, Dark. Stale mark. |
| Open in editor / file manager / reveal in Finder | 656 | not built | No open-in-editor or Reveal in Finder (only `NSWorkspace.open` for paths). |
| Tray / menu bar icon | 658 | not applicable | The official app has no tray. Checklist says do not build. |
| Desktop settings stores (client settings, saved environments, connection catalog) | 659 | partly built | UserDefaults stores (`ClientSettingsStore`, environments). Row note says no client settings store; one exists. |
| CLI shim install (`t3` command) | 661 | milestone 9 | CLI shim install. |
| macOS permission helper and settings window | 662 | not built | No permission helper for Screen Recording or Accessibility. |
| Auto-update (check, download, install on restart, state machine) | 668 | milestone 9 | Updater work. |
| Update channels (stable, nightly) | 669 | milestone 9 | Updater work. |
| Release notes in sidebar pill | 670 | milestone 9 | Updater work. |
| Update toasts | 671 | milestone 9 | Updater work. |
| Remote desktop update of a connected machine | 672 | milestone 9 | Updater work. |
| Custom scheme `t3code://app` serves the renderer (internal, not user-facing) | 678 | not applicable | Internal to the Electron renderer. |
| `t3code://` open-url handling for provider auth hand-off and resume (Codex OAuth callback) | 679 | not built | `App/Resources/Info.plist` registers no URL scheme; no open-url handler. |
| Default protocol client registration | 680 | milestone 9 | Info.plist registration at packaging time. |
| Pairing link (`/pair#...`) handling when opened | 681 | not built | No handler for pairing links opened from outside. |

## Remaining work

Every partly built and not built row sits in one package. Rows owned by the other agent (Usage, Scheduled tasks and the rows tied to them) are left out.

### WP-A Sidebar and command palette leftovers (32 rows)

Rows: 32, 34, 36, 38, 39, 42, 48, 50, 51, 52, 53, 54, 55, 56, 59, 62, 66, 68, 69, 437, 438, 439, 440, 442, 445, 446, 448, 450, 451, 452, 453, 455

### WP-B Thread view leftovers (31 rows)

Rows: 75, 76, 77, 78, 79, 80, 90, 91, 92, 95, 98, 103, 104, 105, 107, 108, 110, 112, 114, 120, 122, 126, 127, 128, 130, 132, 133, 134, 135, 137, 141

### WP-C Composer, terminal and git leftovers (25 rows)

Rows: 147, 148, 149, 155, 156, 160, 161, 162, 164, 173, 179, 180, 183, 184, 222, 230, 231, 232, 245, 246, 254, 257, 260, 261, 526

### WP-D Diff, files, browser and device panels (24 rows)

Rows: 191, 192, 193, 194, 195, 196, 197, 198, 199, 204, 207, 212, 216, 217, 218, 219, 220, 369, 370, 371, 372, 528, 613, 614

### WP-E Settings and appearance behavior (24 rows)

Rows: 281, 285, 300, 302, 307, 309, 311, 313, 315, 316, 324, 325, 326, 327, 328, 329, 330, 331, 332, 340, 389, 390, 426, 427

### WP-F Providers, source control and remote environments (27 rows)

Rows: 354, 355, 356, 357, 358, 359, 360, 363, 373, 385, 386, 404, 405, 406, 408, 409, 410, 411, 569, 571, 572, 573, 576, 577, 578, 579, 582

### WP-G Notifications, onboarding and desktop parts (38 rows)

Rows: 295, 296, 312, 346, 347, 539, 540, 541, 542, 543, 544, 545, 552, 553, 554, 555, 556, 557, 558, 559, 560, 561, 615, 616, 617, 632, 633, 636, 639, 648, 650, 651, 652, 656, 659, 662, 679, 681

### Needs the user's decision first (4 rows)

Rows: 67, 93, 94, 102

Total in packages: 205.

Row numbers are line numbers in `docs/parity-checklist.md` after its legend gained the `M9` and `n/a` lines (commit 28b1c1e); the first version of this file counted two lines lower.
