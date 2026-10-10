# T3 browser panel: how hosting and agent control work

Source: /Users/mrm/CandyWrapper-research/t3code, tag v0.0.46-nightly.20261009.2861. All paths below are relative to that directory. Read-only research, nothing was built or run.

## Summary

1. In this version no client can register to host an agent-controlled browser. The T3 server hosts every agent tab in its own headless Chrome, driven by Playwright. Clients only view and steer those tabs through `/api/preview-stream`.
2. The one exception is the Electron app. It can lend its `<webview>` to the server, but only over two file descriptors that the Electron app passes to the server process it launched. A client that connects to a running server over WebSocket cannot do this.
3. The agent-facing preview actions are high level (open, click, snapshot and so on) and are implemented in the server with Playwright. The client never sees them. The CDP surface a client would need to serve is "whatever Playwright sends", relayed untouched.
4. Recommendation: do not host. Build CandyWrapper's browser panel as a viewer and controller of server tabs. Details at the end.

## 1. Who hosts a browser session

### The server is the host

- The server registers itself with the preview automation broker as the only agent-facing host: `apps/server/src/preview/ServerBrowser.ts:2409-2420`, client id `server-browser` (`packages/contracts/src/previewAutomation.ts:886`), `preferred: true`.
- The broker prefers a `preferred` host over any other connected host when it picks a host for a request: `apps/server/src/mcp/PreviewAutomationBroker.ts:548-557` (sort order), with the doc comment at `:58-63`.
- The broker has `connect`, `focusHost`, `respond` and `invoke` (`PreviewAutomationBroker.ts:66-81`). Only `ServerBrowser.ts` calls `connect`. There is no RPC for a client to call it. `packages/contracts/src/rpc.ts:283` is an empty import `import {} from "./previewAutomation.ts"`, and `WS_METHODS` lists only `preview.open/navigate/resize/adjust/refresh/close/list/clearProfile/reportProfiles/reportStatus` plus `subscribePreviewEvents` and `subscribeDiscoveredLocalServers` (`rpc.ts:439-449, 560-561`).
- Leftover trace of an older design: the broker still accepts `supportedOperations` and a `focused`/`liveTabs` host model (`PreviewAutomationBroker.ts:189-192, 453-475`), and `previewAutomation.ts:44-49` says some operations are "advertised by current desktop hosts". Nothing in this version wires a client to it.
- The agent's `preview_open` always creates a tab with `runtime: "server"`: `ServerBrowser.ts:1136-1142`.

### Capability a client sees

- The server advertises `capabilities.serverBrowser: true` in the environment descriptor: `apps/server/src/environment/ServerEnvironment.ts:261`, schema at `packages/contracts/src/environment.ts:211-214`.
- Doc comment: the server "hosts preview tabs in its own headless Chromium (`runtime: "server"`) and streams them over `/api/preview-stream`. Clients without a local browser runtime open server tabs here."
- `PreviewOpenInput.runtime` is optional. `server` requires that capability: `packages/contracts/src/preview.ts:238-240`.
- Clients send no registration. They only report their browser profiles with `preview.reportProfiles` (`preview.ts:285-290`, `ws.ts:2902`) so agents can choose a profile.

### What the web and Electron clients do

- `previewRuntimeFor` (`apps/web/src/browser/previewRuntime.ts:20-29`): if the environment has no `serverBrowser`, open a local (desktop) tab. If the client is Electron and the environment is not its primary environment, open a local tab. Otherwise open a `server` tab.
- Only Electron looking at its own primary environment renders server tabs natively: `previewRuntime.ts:61-72`. Every other client streams them. `docs/user/remote-access.md:182-196` says the same.

### The Electron fd channel

- Contract: `packages/contracts/src/desktopBrowser.ts:1-46`. Messages are NDJSON over two bootstrap file descriptors, "so only that one server can reach the desktop's pages; nothing listens on a port". Events from the desktop: `attached`, `detached`, `cdp{message}`. Commands from the server: `cdp{message}`, `release`, `pointer{phase,x,y}`.
- fds are set up in `apps/desktop/src/backend/DesktopBackendConfiguration.ts:574-575` (fd 6 and 7) and `DesktopBackendManager.ts:481-490`. The server side is `apps/server/src/preview/DesktopBrowserChannel.ts:73-93`. With no fds it returns `available: false` and `endpoint` dies with "No desktop app is attached to this server."
- When the channel is available, a new server tab waits up to 10 seconds for the desktop's webview to attach (`ServerBrowser.ts:95-96, 713-722`). If none attaches, `createTab` falls back to headless Chrome (`ServerBrowser.ts:748-790`).
- The server wraps the relayed endpoint in a loopback WebSocket for Playwright: `DesktopBrowserChannel.ts:144-202`.
- CandyWrapper talks to the user's login-agent server (`com.t3tools.t3code.service`). That server was not launched by CandyWrapper, so it has no fds for CandyWrapper. This path is closed to us.

### When no client can host

- Not applicable in the sense asked. The server does not need a client.
- It uses its own headless Chrome for Testing 154.0.8037.92, a headless shell downloaded on first use (mac-arm64 99,221,129 bytes): `apps/server/src/preview/PreviewBrowser.ts:15-60`. `docs/user/remote-access.md:190-193` says the first tab downloads about 120 MB.
- The first `open` may take up to 660 seconds because of that install: `PreviewAutomationBroker.ts:564-565`.
- If the browser cannot start (blocked sandbox, missing libraries), the viewer WebSocket closes with code 4503 and a JSON reason `{need, command}` (`preview.ts:162-176`, `ServerBrowserStream.ts:93-103, 121-126, 203-212`). On macOS this is not expected: `docs/user/remote-access.md:211-212` says macOS runs the browser as is.
- The broker returns `PreviewAutomationNoAvailableHostError` only if no host is connected at all (`PreviewAutomationBroker.ts:604-612`). Its message still says "Preview tools run in a T3 Code desktop app" (`previewAutomation.ts:915-930`), which is stale text for this version. The server host reconnects after a 1 second delay (`ServerBrowser.ts:96, 2434-2440`), so the gap is small.
- If the user turns "Agent browser access" off, tools return `PreviewAutomationUnavailableError` (`previewAutomation.ts:845-857`).

## 2. Wire protocol

### Server to agent (not our concern)

The agent calls MCP tools on the server. Names are at `apps/server/src/mcp/toolkits/preview/tools.ts:65-305`: `preview_status`, `preview_open`, `preview_dialog`, `preview_navigate`, `preview_resize`, `preview_set_appearance`, `preview_snapshot`, `preview_click`, `preview_type`, `preview_hover`, `preview_select`, `preview_drag`, `preview_upload`, `preview_press`, `preview_scroll`, `preview_evaluate`, `preview_wait_for`, `preview_recording_start`, `preview_recording_stop`. Also `t3_preview_list` and `t3_preview_close` (`previewControls/tools.ts:25, 40`).

The broker maps each tool to an operation: `status, open, navigate, snapshot, click, type, press, scroll, evaluate, waitFor, recordingStart, recordingStop, resize, setColorScheme, dialog, close, upload, hover, select, drag` (`previewAutomation.ts:29-60`). That is 20 operations. Request shape `PreviewAutomationRequest` (`previewAutomation.ts:801-812`) and response shape `PreviewAutomationResponse` (`:827-844`) exist, but only the server's own host uses them.

### Server to hosting client (Electron only)

- Transport: the fd channel above. Payload: raw CDP JSON strings, multiplexed by `{threadId, tabId}`.
- `CdpRelay` (`apps/desktop/src/preview/CdpRelay.ts`) presents the tab as a minimal CDP browser endpoint for Playwright.
- Browser-level commands it answers itself (`CdpRelay.ts:59-157`): `Target.setDiscoverTargets`, `Browser.grantPermissions`, `Browser.resetPermissions`, `Browser.cancelDownload` (acknowledged), `Browser.setDownloadBehavior` (forwarded), `Browser.getVersion`, `Target.getTargetInfo`, `Target.getBrowserContexts`, `Target.getTargets`, `Target.attachToBrowserTarget`, `Target.attachToTarget`, `Target.detachFromTarget`, `Target.setAutoAttach`. Anything else at browser level throws "Not supported for a desktop preview tab".
- Everything with a page session goes to the tab's debugger unchanged (`CdpRelay.ts:160-170`), except `Runtime.runIfWaitingForDebugger` on the root page, which is swallowed.
- Events relayed back: all page events, plus `Browser.download*` on the root session (`CdpRelay.ts:208-222`). It synthesizes `Target.attachedToTarget` once after `setAutoAttach` (`:143-153`).
- The relay also sets the download directory, so the server's Playwright can read files from disk. That assumes a shared disk (`CdpRelay.ts:24-29`).

### The CDP methods

- Explicit CDP calls in T3's own server code (from `grep` on `apps/server/src/preview`): `Page.startScreencast`, `Page.stopScreencast`, `Page.screencastFrameAck`, `Page.screencastFrame` (event), `Page.captureScreenshot` (`ServerBrowserPage.ts:170`), `Page.getLayoutMetrics` (`:162`), `Page.getNavigationHistory` (`ServerBrowser.ts:561`), `Page.reload`, `Input.dispatchMouseEvent`, `Input.dispatchKeyEvent`, `Input.insertText`, `Runtime.evaluate` (`ServerBrowserPage.ts:441`), `Runtime.terminateExecution` (`:432`), `Network.clearBrowserCookies`, `Network.clearBrowserCache`, `Emulation.setDeviceMetricsOverride`, `Emulation.setUserAgentOverride`, `Browser.getVersion`. That is 17 distinct calls (some are used only for headless tabs).
- On top of this, every Playwright call (`page.goto`, `locator.click`, `page.ariaSnapshot({mode:"ai"})`, `waitForLoadState`, `emulateMedia`, `setInputFiles`, dialog and file chooser events, downloads, popups) emits its own CDP traffic. playwright-core 1.60.0 is pinned (`apps/server/package.json:52`). It is not installed in the research checkout, so I could not list those methods from source.
- From general knowledge of Playwright (unverified here): it uses roughly 100 methods across `Page`, `Runtime`, `DOM`, `DOMSnapshot`, `Accessibility`, `Input`, `Emulation`, `Network`, `Fetch`, `Target`, `Browser`, `Log`, `Security`, `Performance` and `Inspector`, plus event streams (`Page.frameNavigated`, `Runtime.executionContextCreated`, `Network.*`, `Page.javascriptDialogOpening`, `Page.fileChooserOpened`, `Target.attachedToTarget`). Treat 100 as an order of magnitude, not a count.
- Conclusion: the surface is "full Chromium CDP page-level" and it depends on Chromium behaviors (isolated worlds, frame trees, trusted input, Fetch interception). A WKWebView shim cannot honestly offer it.

### Server to viewer client (the usable protocol)

This is `GET /api/preview-stream/ws?threadId&tabId&maxWidth&maxHeight&quality&interactive` as a WebSocket upgrade, plus two HTTP routes. Source: `apps/server/src/preview/ServerBrowserStream.ts`, client reference `packages/client-runtime/src/preview/serverBrowserStream.ts`.

- Auth: `authenticateMediaRequest` with read scope, and operate scope for input (`ServerBrowserStream.ts:72-76`). Bearer or DPoP clients pass a short-lived ticket in the query via `withDeviceHubQuery` (`client-runtime/src/device/hubAccess.ts`). Base path `/api/device-hub` in the client; server prefix `/api/preview-stream` (`serverBrowserStream.ts:10`).
- Server to client, binary: one complete JPEG per message. The client must send `{"type":"ack"}` for each frame (`serverBrowserStream.ts:215-219`). The server drops viewers with 64 unacknowledged frames or an 8 MB buffer (`ServerBrowserStream.ts:33-34, 130-150`). Pacing is about 100 ms per ack, so roughly 30 fps at best (`ServerBrowser.ts:93-94`).
- Server to client, JSON: `viewport{width,height}`, `control{canOperate,controller("agent"|"you"|"another-viewer"|"unclaimed"),generation,dialog|null}`, `clipboard{text}`, `download{id,fileName,sizeBytes}`, `fileChooser{id,multiple,accept}`, `fileChooserClosed{id}`, `popup{tabId}`, `pointer{phase,x,y,sequence}`, `probe{x,y,editable}` (`ServerBrowser.ts:159-205`, `ServerBrowserStream.ts:153-163`).
- Close codes: 4404 tab gone, 4503 host setup needed (JSON reason), 1012 reconnect (`ServerBrowserStream.ts:30, 116, 121-126, 167-170`).
- Client to server, JSON (`serverBrowserStream.ts:49-96`, handled at `ServerBrowser.ts:2037-2155`): `takeControl`, `releaseControl`, `dialog{accept,promptText?}`, `viewport{setting}`, `mouse{action:move|down|up,x,y,button,buttons,clickCount,modifiers}`, `wheel{x,y,deltaX,deltaY,modifiers}`, `key{action,key,code,keyCode?,text?,modifiers}`, `text{text}`, `resize{width,height}`, `navigate{url}`, `history{delta:-1|1}`, `reload{ignoreCache?}`, `probe{x,y}`. Coordinates are page CSS px. Modifier bits: Alt 1, Ctrl 2, Meta 4, Shift 8 (`serverBrowserStream.ts:187-195`).
- HTTP: `GET /api/preview-stream/download?threadId&tabId&id` serves a finished download (`ServerBrowserStream.ts:214-230`). `POST /api/preview-stream/upload?threadId&tabId&chooser` takes multipart `file` parts (up to 20 files, 100 MB total) and answers the page's file picker; no parts cancels it (`:232-275`).
- Control model: one owner per tab at a time (agent, one viewer, or nobody). `SessionControl` serializes actions and drains running work before a new owner acts (`apps/server/src/preview/SessionControl.ts:14-60`). Read-only viewers can watch only.

### Session state RPCs a client does use

- `preview.open/navigate/resize/adjust/refresh/close/list`, `preview.reportStatus`, `preview.reportProfiles`, `preview.clearProfile`, and the stream `subscribePreviewEvents` (`rpc.ts:1435-1495`).
- `PreviewSessionSnapshot` carries `navStatus`, `canGoBack/Forward`, `viewport`, `colorScheme`, `zoomFactor`, `profileId`, `runtime`, `automationOwner`, `reveal`, `revealRequest`, `updatedAt` (`preview.ts:186-213`).
- Events: `opened`, `navigated`, `resized` (with optional `hardReload` or `clear: cookies|cache`), `failed`, `closed`, with `serverEpoch` and monotonic `revision` (`preview.ts:329-390`).

## 3. Agent actions and whether a WKWebView could do them

This table only matters for option (b), a client that pretends to be a CDP host. Today that is blocked by the transport (section 1), not by WKWebView.

| Action | CDP or Playwright need | WKWebView | Rating |
|---|---|---|---|
| open | `Target.*` plus `Page.navigate` | create the view, `load(URLRequest)` | easy |
| navigate | `Page.navigate`, lifecycle events | `load`, `WKNavigationDelegate` for commit and finish. `domContentLoaded` readiness needs an injected `DOMContentLoaded` message | easy |
| click | `Input.dispatchMouseEvent` (trusted, hit-tested) | `evaluateJavaScript` can dispatch synthetic events, but `isTrusted` is false and some pages ignore them. Real input needs AppKit mouse events sent to the view, which works only while the view is in a window | possible with caveats |
| type | `Input.insertText` / key events | focus via JS then synthetic events, or send real `NSEvent` keys. IME and `contenteditable` edge cases | possible with caveats |
| press | `Input.dispatchKeyEvent` | real key `NSEvent` to the view, or synthetic `KeyboardEvent`, which does not trigger default actions | possible with caveats |
| scroll | wheel event or `scrollBy` | `evaluateJavaScript("scrollBy")` or `scrollView` | easy |
| select (native `<select>`) | Playwright `selectOption` | set `.value` and fire `input`/`change` in JS | easy |
| hover | `Input.dispatchMouseEvent` move | JS cannot trigger real `:hover` CSS. Only `NSEvent` mouse moves do, and only with a window | possible with caveats |
| drag | mouse down/move/up sequence, HTML5 drag events | real HTML5 drag-and-drop is poor in WKWebView through synthetic events. Pointer-based draggers work with real `NSEvent` | possible with caveats |
| upload | `DOM.setFileInputFiles`, file chooser event | `WKUIDelegate runOpenPanel` answers a picker. Setting files on an `<input type=file>` directly means building a `File` and `DataTransfer` in JS from bytes | possible with caveats |
| dialog | `Page.javascriptDialogOpening/handle` | `WKUIDelegate` alert/confirm/prompt completion handlers. Hold the handler until the agent answers | easy |
| wait for | polling `locator.count()`, text, URL | JS polling plus `url` observation | easy |
| evaluate | `Runtime.evaluate` (awaitPromise, returnByValue, terminate) | `callAsyncJavaScript` handles promises. No way to terminate a runaway script short of reloading the view | easy (timeout kill is weak) |
| snapshot | `ariaSnapshot({mode:"ai"})` with `aria-ref` locators, console and network buffers, screenshot | accessibility tree and refs must be rebuilt in injected JS and will not pierce cross-origin frames. Console and network entries need injected hooks. Screenshot via `takeSnapshot` | possible with caveats |
| screenshot | `Page.captureScreenshot` | `takeSnapshot(with:)`, with a clip rect. Fine for visible area | easy |
| recording | `Page.startScreencast` plus encoder | no screencast. Poll `takeSnapshot` at 10 to 20 fps and encode with AVAssetWriter. The agent cursor overlay is drawn by the client | possible with caveats |

Counts for the 16 rows: 8 easy (open, navigate, scroll, select, dialog, wait for, evaluate, screenshot), 8 possible with caveats (click, type, press, hover, drag, upload, snapshot, recording), 0 not possible. The "caveats" ones include the three that agents lean on most (click, type, snapshot), and the snapshot and `aria-ref` model is Playwright specific.

Not in the table but needed by the server host model: `resize` (viewport emulation, easy to approximate by view size), `setColorScheme` (`WKWebView` has no per-view `prefers-color-scheme` override; `overrideUserInterfaceStyle` on the view works), `close` (easy).

## 4. Pick, annotate, port discovery, PiP, tabs, zoom, favicon, incognito, import

### Pick element and annotate

- Desktop only. It uses Electron IPC and a webview preload, not the server. The streamed viewer (`apps/web/src/browser/ServerBrowserSurface.tsx`) has no pick or annotate code (`grep` finds none).
- Flow in Electron: the renderer calls `previewBridge.pickElement(tabId)` (`apps/web/src/components/preview/PreviewView.tsx:831`). The main process sends `preview:start-pick` to the guest, with the annotation theme (`apps/desktop/src/preview/Manager.ts:2325`, channel names in `GuestProtocol.ts:1-13`). The preload `PickPreload.ts` (1475 lines) draws the overlay, collects elements with `react-grab/primitives` `getElementContext` (React fiber name and source frame), regions, ink strokes, and style edits. It sends `preview:element-picked` with the payload, a crop rect, `"attach"|"send"` and device pixel ratio (`Manager.ts:2236-2246`).
- Main validates the payload with `isPreviewAnnotationPayload` (`PickedElementPayload.ts:70-146`), takes a full `capturePage()` with retries, crops it, and returns `{annotation, submission, screenshotFailed?}` (`Manager.ts:2255-2290`). It also ends the pick on navigation or destroy (`:2290-2300`).
- Payload types: `PickedElementPayload` has `pageUrl, pageTitle, tagName, selector, htmlPreview, componentName, source{functionName,fileName,lineNumber,columnNumber}, stack[], styles, pickedAt`. `PreviewAnnotationPayload` has `id, pageUrl, pageTitle, comment, elements[{id,element,rect}], regions[{id,rect}], strokes[{id,color,width,points,bounds}], styleChanges[{targetId,selector,property,previousValue,value}], screenshot{dataUrl,width,height,cropRect}|null, createdAt` (`packages/contracts/src/ipc.ts:840-1004`).
- Reaching the composer: `addPreviewAnnotation(threadRef, annotation)` stores it in the draft store (`PreviewView.tsx:852`). The crop is also added as an image attachment (`:863-880`). On send, the composer builds `message.context.records` (`docs/internals/composer-context-references.md:121-135`). The wire records are `ElementContextRecord` (`kind:"element"`) and `PreviewAnnotationContextRecord` (`kind:"preview-annotation"`, with `annotationId, pageUrl, pageTitle, comment, targetSummary, styleChanges[], elements[], elementIds[], regionCount, strokeCount, styleChangeDetails[], screenshotContextId`) in `packages/contracts/src/composerContext.ts:130-185`. The chip is rendered by the client from those records. The screenshot travels as its own image record. The server projects them for the provider at turn start.
- What a native client needs: a way to inject a script and get messages back (`WKUserScript` plus `WKScriptMessageHandler`), a pixel capture (`takeSnapshot`), and code to build the records. The element-picking script, the overlay UI and the React-fiber lookup would have to be rewritten or the react-grab bundle shipped as a resource. No server support is needed beyond the normal message `context.records`. This only works for a page that CandyWrapper itself renders in a WKWebView. A streamed server-tab image cannot be picked from, because there is no DOM on our side (Electron's streamed viewer does not offer it either).

### Local server discovery

- Stream RPC `subscribeDiscoveredLocalServers` with optional `configuredUrls` (up to 32 loopback URLs, `preview.ts:11-17`), returning `DiscoveredLocalServerList {servers[{host,port,url,processName,pid,terminal{threadId,terminalId}|null}], scannedAt, configuredUrlProbing?}` (`preview.ts:393-424`, `rpc.ts:1497-1504`, handler `ws.ts:2924`, scanner `apps/server/src/preview/PortScanner.ts`).
- Web wrapper: `apps/web/src/portDiscoveryState.ts:46-73` (also filters by thread via `terminal.threadId`, `:75-90`).
- The scan runs on the server host. On our machine the server and the app share one Mac, so `localhost` means the same thing for both. The agent's `preview_navigate` accepts `{kind:"environment-port", port}` (`previewAutomation.ts:219-235`).
- Client needs: subscribe to this stream. No browser capability required.

### Mini player (PiP)

- Streamed tabs: `serverPictureInPicture.ts` draws the JPEG frames to a canvas, `captureStream()`, and puts that video in browser Picture-in-Picture (Chromium or Safari). Pure web feature.
- Electron native tabs: a separate small window fed by main-process frames over IPC (`apps/desktop/src/preview-pip-preload.ts:1-17`, channel `PREVIEW_PICTURE_IN_PICTURE_FRAME_CHANNEL`).
- In-app floating mini player: `ThreadPreviewMiniPlayer.tsx` and `previewMiniPlayerLayout.ts`. It is client-local layout, sized by the user.
- Client needs: nothing from the server. For us, an `NSPanel` or a floating child view showing the same frames.

### Tabs

- Per thread, many tabs. Tab ids are server-created and opaque (`preview.ts:25-26`). The server owns the list. `preview.list` returns it and `subscribePreviewEvents` keeps it live, with `serverEpoch` plus `revision` to drop stale lists (`preview.ts:292-327, 329-390`).
- The agent's `preview_status.tabs` lists every server tab in the thread with owner and `ownedByCaller` (`previewAutomation.ts:131-148`). Popups become new tabs with `openerTabId` (`ServerBrowser.ts:895-905`), and the viewer receives a `popup{tabId}` message to switch to it.
- Client needs: render tab strip from snapshots, call `preview.open/close/navigate/refresh`.

### Zoom

- Server tabs: `preview.adjust {zoomFactor}` from any client. The server applies it with `Emulation.setDeviceMetricsOverride` (`ServerBrowser.ts:625-640`). Levels are the Chrome ladder `[0.25 ... 5.0]` (`preview.ts:104-122`). The web client steps through them (`PreviewView.tsx:357-376`).
- Electron native tabs: `webContents.setZoomFactor` (`Manager.ts:922, 1871`).
- Client needs: send `preview.adjust`. Nothing else. A WKWebView tab would use `pageZoom`.

### Favicon

- Electron captures favicons in the main process (`apps/desktop/src/preview/FaviconCapture.ts`, up to 8 candidates, 100 KB, data URLs) and stores them in a client store keyed per thread and origin (`apps/web/src/browserFaviconStore.ts`).
- Streamed tabs: the stream carries no favicon. I found no server favicon code in `apps/server/src/preview`. The web client shows what it cached or a fallback.
- Client needs: fetch `/favicon.ico` or the page's `<link rel=icon>` itself if it wants an icon for a streamed tab. Optional.

### Incognito and profiles

- Built-ins: `default` (persistent) and `incognito` (throwaway), plus up to 24 user profiles (`packages/contracts/src/browserProfile.ts:25-79`).
- For server tabs the profile maps to a Playwright persistent context directory on the server (`ServerBrowserContexts.ts:167-190`). Incognito, and agent tabs with no profile, get an isolated context per tab (`ServerBrowser.ts:758-766`, `ServerBrowserContexts.ts:167-172`).
- The client reports its profile list with `preview.reportProfiles {profiles, defaultProfileId}` (in memory on the server, so resend on connect and on change, `ServerBrowser.ts:225-235`). `preview.clearProfile` deletes a profile's server-side storage. `preview.adjust {clear:"cookies"|"cache"}` clears one.
- Client needs: store profile list locally and report it. Pass `profileId` on `preview.open`.

### Browser import

- Desktop only (`apps/desktop/src/preview/BrowserImport/`, contracts `browserImport.ts`). It reads cookie databases from Chrome, Edge, Brave, Vivaldi, Opera, Arc, Helium, Firefox, Safari. It decrypts via Keychain, needs Full Disk Access for Safari, and writes cookies into the Electron session partition for the target profile. Only cookies, not passwords (`browserImport.ts:1-12`, `docs/user/browser-import.md`).
- It writes into Electron partitions. Nothing in the server API imports cookies into a server profile. So even an Electron import does not reach a server tab's profile.
- For us: skip, or do a later feature that injects cookies into `WKHTTPCookieStore` for a local-only WKWebView tab. It cannot help agent tabs, which run in the server's Chrome.

## 5. Recommendation

Option (c): do not host and do not shim CDP. Make the browser panel a native viewer and controller of server tabs.

1. Hosting is closed to us. The only host registration path is the Electron fd channel, and it is bound to the server Electron launched. Our server is T3's login agent.
2. A CDP shim is the wrong size. The server drives hosts through Playwright, which needs far more of CDP than a WKWebView can fake (trusted input, isolated worlds, frame sessions, `aria-ref` snapshots).
3. The server already works without us. On this Mac it runs headless Chrome, which the agent controls, and the user watches. Every agent action works as soon as the panel can show the tab.

What to build for the panel:

- Draw JPEG frames from `/api/preview-stream/ws` into a custom view, ack every frame, and send `mouse`, `wheel`, `key`, `text`, `resize`, `navigate`, `history`, `reload` input.
- Handle `control` (take or release control, dialog buttons), `fileChooser` (NSOpenPanel then POST upload), `download`, `popup`, `clipboard`, `pointer` (agent cursor), `viewport`.
- Use the preview RPCs and event stream for tabs, nav state, zoom, appearance and profiles. Read the `serverBrowser` capability first.
- Port discovery from `subscribeDiscoveredLocalServers`.
- Mini player and favicon are local.

Where WKWebView still fits: tabs the user opens for themselves in a `desktop`-runtime tab that the agent cannot see or drive. Pick and annotate would work only there. Decide whether that is worth a second code path. The CLAUDE.md rule allows WKWebView for the built-in browser, but a viewer-only panel avoids it for server tabs and keeps "created only while visible" trivial (a WebSocket and a bitmap view).

Open questions for the user:

- Does the user want agent tabs only (viewer, no pick/annotate), or also local WKWebView tabs with pick and annotate?
- Is wire compatibility satisfied by never opening `desktop`-runtime tabs? Unknown without testing: the server must tolerate a `desktop`-runtime snapshot reported by CandyWrapper through `preview.reportStatus`, as Electron does for remote environments. Not verified.
