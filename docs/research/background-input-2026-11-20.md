# Driving a test app from behind, 2026-11-20

Several agents share one screen. These notes record what `scripts/ui` can do to a test app that is not frontmost and is covered by another window, so agents can test at the same time without `scripts/ui/screen-lock`.

Measured on the Mac mini M2 Pro, macOS 27.2.1, one 1920x1080 display at 1x, with a Debug CandyWrapper started by `scripts/run-app ... --background` against the 4928 sandbox server. A magenta window from another process covered the app the whole time, and Finder stayed frontmost.

## What works

| Operation | Without the lock | How |
|---|---|---|
| Picture of a covered window | works | `shot`, which runs `screencapture -l` per window and stacks child windows in window order |
| Picture of a window partly off screen | works, full size | same; a window moved 680 points past the right edge came out whole |
| Picture of a window on another Space | untested | there is no way to make a Space here without System Events |
| Picture at 2x | untested | this Mac has no 2x display; `shot` reads the scale from the picture |
| Popovers, context menus, the command palette, Settings | captured | CandyWrapper draws them inside the main window |
| Recording a covered window | works | `record`, ScreenCaptureKit filtered to the app: 40 frames in 3 s, palette opening and closing |
| Key equivalents (⌘K, ⌘,, Escape) | works | `key`, posted to the pid |
| Typing into the field that has focus | works | `type`, posted to the pid |
| Clicking a button or a sidebar row | works with `--background` | `click`; see below |
| Right-click context menu | works with `--background` | `click x y right` |
| Opening a popover by click, closing it with Escape | works with `--background` | |
| Double-click | works with `--background` | opened a row's rename field |
| ⌘-click | flaky with `--background` | selected a second row in 1 of 2 tries |
| Scrolling | works with `--background` | `scroll`; the event needs the window number field |
| Clicking a text field, then typing | unreliable | the composer did not take focus in 4 tries; type where focus already is, or open the palette with ⌘K, which focuses its own field |
| Hover, tooltips, mouseMoved | needs the lock | AppKit builds mouseEntered from the real pointer; posted moves did nothing |
| Drags, drag and drop, drag selection | needs the lock | a posted drag selected nothing |
| Pinch and other gestures | needs the lock | untested, no tool posts them |
| Native menus (menu bar, pop-up buttons) | needs the lock | untested; menu tracking follows the real pointer |

No case needs a key window without needing the lock as well. A window can only be key while its app is active, and AX can't change that: setting `AXMain` and `AXFocused` on the window returns success and leaves it non-key and the app inactive.

## Why clicks need `--background`

AppKit gets an event posted with `CGEvent.postToPid` but treats a mouse-down on a window of an inactive app as the click that would activate it. Views that don't accept first mouse, which is nearly all of CandyWrapper's, never see it. The app can't become active without taking the screen, so `MainWindow.sendEvent` in a `--background` launch hands mouse-down, drag and mouse-up to the view under the point itself, makes that view first responder like AppKit does, and routes scroll events by their global location.

The same flag skips `NSApp.activate()` at launch and opens the window behind the other apps. While the app is inactive, its window ignores requests to come forward, so a background test app never covers the app another agent has in front.

## Event details

- A mouse event posted to a pid needs a window location that AppKit trusts. Only an `NSEvent` built with `mouseEvent(with:location:...windowNumber:...)` and turned into a `CGEvent` carries one. A plain `CGEvent` arrived at (-1, 781).
- AppKit flips that location through the main display's height on the way in, so the tools pass `displayHeight - (y - windowTop)` as the y coordinate.
- A scroll can't be built as an `NSEvent`. Without event field 51, the window number, AppKit drops it before `sendEvent`.
- Posted events don't move the real pointer and don't change the HID modifier state.

## Capture details

- ScreenCaptureKit's daemon, replayd, stopped answering for minutes while two `shot` processes asked at once, at 76% CPU. `screencapture -l` kept working, so `shot` uses it and `record` exits after a watchdog instead of hanging.
- `CGWindowListCreateImage` is unavailable in the macOS 27 SDK.

## Permissions

The tools need Screen Recording (window titles, `screencapture`, ScreenCaptureKit) and Accessibility (posting events, `axpress`). On this Mac only the live T3 runtime has them, and processes it starts, such as an agent's shell, inherit them. Nothing new had to be granted. Nothing here uses osascript or System Events.

## Two apps at once

Two test apps with their own bundle ids sat at the same place on screen under the magenta window. Two shells drove them at the same time with no lock. Each `shot` showed its own app in its own state, the screen region stayed magenta, and Finder stayed frontmost. Pictures are in `/tmp/cw-agent-speed-proof2`: `proof-A.png` has A's palette, scrolled sidebar and Settings, `proof-B.png` has B's context menu and model popover, `screen-after.png` is the screen during the run, `rec-A/` is A's recording, and `A5-offscreen.png` is A moved partly off screen.
