# MCP preview fullscreen takeover

The user reported a Blender capture preview covering the CandyWrapper window without clicking an expand control. The screenshot matches the native `ThreadMcpFullscreenView` host. An MCP document can issue `ui/request-display-mode` as soon as it initializes, and the previous host granted fullscreen without user activity. The exact Blender document was not inspected, so the triggering message is inferred from this code path and the report rather than a recorded live trace.

## Behavior

Background display-mode requests now return the current mode and keep the preview inline. Fullscreen requests need recent interaction with the focused preview in the key window. A native Open app full screen button provides an explicit expansion action for every MCP preview. This deliberately differs from T3's automatic expansion while retaining the same MCP request and response shapes.

An expanded app no longer occupies an inline web-view budget slot. New inline results previously could evict its web view while leaving the fullscreen host visible. This is a separate reproducible blanking path, not proof of what made the user's capture black. Closing or reusing the row restores the budget and tears the view down as before. Fullscreen scrolling belongs to the app; inline scrolling returns to the timeline. Escape reaches the fullscreen host's close action through the responder chain.

## Source and checks

At `T3_VERSION`, `apps/web/src/components/chat/McpAppFrame.tsx:341-353` accepts app-initiated expansion unless another modal, runtime request or fullscreen app blocks it. Lines 187-204 provide focus and Escape dismissal; lines 459-476 draw the fullscreen exit control. CandyWrapper keeps its existing modal checks and adds the user-activity requirement.

`McpFullscreenTests` checks an unsolicited request, the actual native expand button, dismissal followed by a delayed request, preservation of the same web view as new inline results exceed the budget, scrolling restoration and reuse cleanup. Together with `WebFrameSandboxTests`, all 12 focused checks passed.

The full suite passed all 1,536 Swift Testing tests and 17 XCTest tests, 1,553 total. The isolated app build passed. After a final expand-button visibility correction, the 12 focused tests were rerun. Diff review found no new timer, polling or retained fullscreen host after row teardown.

Real-window checks passed in light and dark using a temporary isolated-app fixture with the production MCP host and a local HTTP capture document. The page requested fullscreen during initialization and displayed the host's inline response. The native expand button preserved the loaded canvas, Escape returned it inline, the page's own clicked expand button received fullscreen, and Exit full screen returned it inline. Fixture launch code was removed from the repository after the check; no test-only entry point ships. Screenshots stay outside git in `~/CandyWrapper-research/sandbox/mcp-fullscreen/`: `cw-mcp-dark-expanded.png`, `cw-mcp-dark-inline.png`, `cw-mcp-light-inline.png`, `cw-mcp-light-app-click.png` and `cw-mcp-light-dismissed.png`. The test app, derived data and fixture HTTP server were stopped or removed.

No Blender account, live thread or live server was accessed. The fix has not been released yet. App CPU and memory were not profiled for this narrow interaction change.

## Remote desktop interruption

Native checks were interrupted by the remote desktop locking. Host logs identify immediate lock requests from Apple's ScreensharingAgent at 09:58 and 10:08, followed by that agent exiting. Sleep and display sleep were already disabled. This points to Screen Sharing restoring the locked state when a connection ends, rather than the test app or an idle timeout. No login or remote-access setting was changed. The user does not want repeated Screen Sharing reconnects to be part of the validation workflow; a permanent solution remains to be established.
