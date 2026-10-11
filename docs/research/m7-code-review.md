# Milestone 7 code review

Scope: `git diff 06c7db5 79e4504 -- App Packages/CandyKit/Sources`, hunted by category with grep and targeted reading. Line numbers point at the working tree after the fixes. Verified with `swift test` (whole suite passes) and the app build.

## Fixed

- `Packages/CandyKit/Sources/Features/Thread/TimelineWebRows.swift:98`, security, high: an HTML render could open any URL scheme (`file:`, app schemes) after a click; now only http and https, as T3's `parseSafeExternalUrl` (ElectronShell.ts:42).
- `Packages/CandyKit/Sources/Features/Thread/TimelineWebRows.swift:239`, security, high: same for an MCP app's `ui/open-link`; non-web links are refused with an error back to the app.
- `Packages/CandyKit/Sources/T3Store/McpAppHostBridge.swift:128`, crash, high: a JSON-RPC id like `1e300` posted by an MCP app page trapped in `Int(n)`; only safe integers convert now. Test `hugeNumericIdsDoNotCrash`.
- `Packages/CandyKit/Sources/T3Protocol/SafeExternalURL.swift:1`, security: new helper mirroring `parseSafeExternalUrl`, test `SafeExternalURLTests.swift`.
- `Packages/CandyKit/Sources/Features/Markdown/MarkdownView.swift:554`, security, medium: message links opened any scheme through NSWorkspace; now http and https only (click, menu and accessibility press).
- `App/Sources/PullRequestsController.swift:80,592,734,741,926`, `PullRequestsPage.swift:110,461`, `ComposerController.swift:2861`, `GitController.swift:884`, `UsageController.swift:98`, security, medium: server-supplied URLs go through `SafeExternalURL.parse` before NSWorkspace opens them.
- `App/Sources/PullRequestsPage.swift:120`, leak, medium: opening Pull Requests while it was already in front called `didShow` again and leaked two event monitors, an observer and a 60 s timer per open; `didShow` now tears the old ones down first.
- `Packages/CandyKit/Sources/Features/PullRequests/PullRequestTabs.swift:57`, leak, medium: `PullRequestScrollWatcher`'s observer block held the clip view and was never removed, so NotificationCenter kept every tab's scroll content alive; removed in `deinit`.
- `Packages/CandyKit/Sources/Features/CommandPalette/ContentSearchView.swift:74`, leak, low: one observer token leaked per content search open; stored and removed in `deinit`.
- `Packages/CandyKit/Sources/Features/Settings/ThemeEditorPanelView.swift:57`, leak, low: `removeObserver(self)` could not remove a block observer, so each superview move added another frame observer; the token is stored and removed.
- `App/Sources/BrowserController.swift:521`, main thread, medium: browser file uploads read whole user files with `Data(contentsOf:)` on the main actor; reading moved to a detached task.
- `Packages/CandyKit/Sources/Features/Settings/AppearanceSettingsView.swift:138`, main thread, low: theme import read the whole chosen file before its 512 KB check; the size is checked first.
- `App/Sources/ComposerController.swift:2039,2065`, `App/Sources/FilesController.swift:386`, `Packages/CandyKit/Sources/Features/Composer/ComposerMenus.swift:714`, `Packages/CandyKit/Sources/T3Protocol/Domain/ProjectClone.swift:31`, `Packages/CandyKit/Sources/Features/Settings/SettingsRowFactory.swift:210`, crash, low: `Int(n)` on server numbers traps on huge values; they use `intValue` or a bounds check.

## Left as notes

- `Packages/CandyKit/Sources/Features/Files/FileSurfaceView.swift:433`, security, medium: workspace HTML loads unsandboxed in the main frame at the server's asset origin with no navigation delegate; T3 uses a sandboxed iframe (BrowserDocumentFrame.tsx:58). The fix wants the `ThreadWebFrameView` host page pattern, a design call.
- `Packages/CandyKit/Sources/Features/Markdown/MermaidDiagrams.swift:100`, main thread, medium: the 3.5 MB Mermaid script is read and lzma-decompressed on the main thread each time the web view starts (it is released after 5 s idle). Move to a background task in M8 with a measurement.
- `App/Sources/GitController.swift:109`, `TerminalController.swift:102`, `BrowserController.swift:93`, `SettingsPages.swift:92`, leak, low: block observers are never removed, but each controller lives as long as its window and captures `self` weakly.
- `Packages/CandyKit/Sources/Features/PullRequests/PullRequestDetailView.swift:203`, `PullRequestCodeView.swift:76`, leak, low: same pattern on views that live for the window.
- `Packages/CandyKit/Sources/Features/Files/FilesLogic.swift:149`, `PullRequests/PullRequestListLogic.swift:120`, main thread, low: regexes compiled per call; cheap at their call rates.
- Wire compatibility: every RPC method name in the app and CandyKit exists in `packages/contracts`; device open, detail and action payloads match `device.ts`. Payload shapes elsewhere were spot-checked only.
- No `try!`, `as!` or `fatalError` on network, JSON or file data was found; the `try!` hits are constant regexes and `init(coder:)`.
