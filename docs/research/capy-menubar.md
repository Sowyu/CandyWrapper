# Capy's menu bar item

Read from Capy 0.5.0 (`/Applications/Capy.app`, Electron 44.9.3) on 2026-10-23. Offsets are byte offsets into
`Contents/Resources/app.asar` → `out/main/main.js` (main process, 2,650,944 bytes) unless a renderer file is named.
Renderer files are in `Contents/Resources/renderer/assets/`. Capy was not run against any account for this.

## Icon

- `Contents/Resources/tray/capyTrayTemplate.png` (16×16) and `@2x` (32×32): a monochrome template image of the Capy face. `kTe` picks it (2579970), and `IB` loads it with `setTemplateImage(true)` on macOS (≈2211700).
- The tooltip is the product name, `setToolTip(e.productName)` (2216370).
- `Contents/Resources/tray-overlay/tray-overlay.node` is a native addon that paints a coloured layer over the status item button. `xNe` loads it on macOS and logs `tray-overlay-unavailable` when it fails (2215691).

## What the item shows

The "Menu bar item" setting picks one of `MT = ["face-counts", "face", "counts"]` (1051089). The default is `XC = {enabled: true, orgId: null, item: "face"}` (1051137). The renderer labels them "Icon only", "Icon and counts" and "Counts only" (`fe` in general-D4mfTeHV.js:977). Its description says "What the menu bar item shows; counts are off by default".

- With "face", or with no threads, the item is the plain template face (`eb`, 2211794).
- With counts, `eb` draws an SVG (`NNe`, from `nC = 22` at 2210715): the face at 16 px, then a 12 px chat-bubble glyph and the thread count in 13 px SF Pro medium. The count is `threads.length`, plus "+" when the server has more pages. The SVG goes through `sharp` into 1× and 2× PNG representations, marked as a template.
- With the overlay addon loaded, the bubble is drawn once more in `#8E8E93` as a coloured layer, so the bubble stays grey while the text follows the menu bar tint.
- There is no working animation, spinner or badge dot. The image changes only when the thread list changes.

## Clicks

On macOS both buttons open the menu. `u.on("mouse-down", () => u.setContextMenu(h()))` rebuilds the menu on every press (2216434). On other platforms a click opens the window instead.

## The menu

`ONe` builds it (≈2214600), top to bottom:

1. The thread list (`TNe`, ≈2213290).
    - Before sign-in: "Sign in to see your threads" (disabled). While loading: "Loading threads…" (disabled).
    - With no threads: "No recent threads" (disabled).
    - Otherwise a disabled "Recent threads" header and up to `bNe = 5` threads (2210770). Each label is `CODE-12  Title`, with the title cut to 47 characters plus "…" (`_Ne`). "Untitled thread" stands in for a missing title. Clicking opens `/thread/<id>` in the window.
    - "View all threads…" when there are more, opening `/threads`.
2. A separator, then "New Thread", which opens `/new` (2214886).
3. While Capy's keep-awake hold is on, a disabled "Keeping awake · N workspaces running" or "Keeping awake · recent activity" line and a separator (`MNe`, 2214402).
4. With the `computer_use_macos` entitlement, a "Computer Use: Grant … permissions" item that opens System Settings, or a disabled "permissions granted" line. While the agent is injecting input there is also "Computer Use: Stop Agent Input".
5. "Quit Capy" with `role: "quit"` (2215268).

## Where the threads come from

`SNe` (≈2207900) asks Capy's API for the signed-in user's threads in the chosen organization. It uses origins web, Slack, Linear, GitHub, API and Capy (`hNe`, 2207995), the page key `"live"` (2208067) and a limit of `gNe = 50` (2205878). The project code joins the thread number to make `CODE-12`.

It refetches when Capy's realtime socket sends a hint for the jam, project or entitlement tables, and only for the columns in `INe` (`mNe`, 2206307). The socket retries with `yNe` backoff. The tray redraws through `ii(t.changes, …)` (2217192), so nothing polls on a timer.

## Settings

All of these sit under Settings > General (general-D4mfTeHV.js:12437-16600, settings-catalog-CO5lULma.js:1676-2128):

- "Show in menu bar", a switch, default on, described as "Keep the Capy icon and thread counts in the menu bar". Turning it off destroys the tray (`s.tray?.destroy()`).
- "Menu bar organization" picks the organization whose threads it follows.
- "Menu bar item" picks the face and counts style (macOS only).
- "Start at login" with "At login: Open window / Stay in menu bar".

## Window close

On macOS `window-all-closed` does nothing (`gP` and `TTe`, 2581093), so Capy keeps running with no window whether or not the tray is on. T3 does the same (apps/desktop/src/app/DesktopLifecycle.ts:244-252).

## CandyWrapper's mapping

`App/Sources/MenuBarController.swift` and `Packages/CandyKit/Sources/Features/MenuBar/MenuBarMenu.swift`:

- The icon is a template image of CandyWrapper's candy (design/icon/glyph.svg), drawn in code.
- Both clicks open the menu, rebuilt in `menuNeedsUpdate` from the sidebar's merged shell.
- "Recent threads" holds the five most recent unarchived threads by T3's `getThreadSortTimestamp` (updated_at), as the palette orders them. T3 threads have no codes, so a row is just the title, cut at 48 characters.
- "View all threads…" opens the command palette, which lists every thread.
- "New Thread" runs the sidebar's new-thread button.
- The keep-awake line becomes "N threads running" (preparing, starting or running), since T3 holds no power assertion.
- "Quit CandyWrapper" goes through the app menu's Quit, so Redesign still asks first.
- Settings > General > Behavior gets "Show in menu bar" (`menuBarItemEnabled`, a local client setting, default on). Redesign shows it under Notifications.

Left out:

- The counts styles and their setting. Capy defaults to the plain face, and counts would mean watching the shell while idle.
- The organization picker, since T3 has no organizations.
- Computer Use and Start at login, which CandyWrapper doesn't have.
- Staying open with no window. CandyWrapper quits when its last window closes (`applicationShouldTerminateAfterLastWindowClosed`), unlike Capy and T3, and this change leaves that alone.
