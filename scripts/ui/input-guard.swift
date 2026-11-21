import AppKit

// Prepended by scripts/ui/build to the tools that post input (click, scroll, key, type, drag, move), after
// windows.swift.
//
// Background mode, the default when CW_UI_PID is set: events go straight to that app's event queue with
// CGEvent.postToPid. The app need not be frontmost or uncovered, the real pointer stays put, and nothing
// reaches the app the user or another agent has in front, so no screen lock is needed. Mouse events carry the
// number of the app's window under the point, so AppKit routes them to it. docs/research/background-input-2026-11-20.md
// lists what works this way.
//
// HID mode, with CW_UI_MODE=hid or without CW_UI_PID: events go through the HID system to whatever app is
// frontmost, as a real keyboard and mouse would, and move the real pointer. That needs the screen lock. A
// stray keystroke once landed in the user's real composer this way, so the tools refuse while the user's demo
// app (pid in /tmp/cw-demo.pid) is frontmost unless CW_UI_ALLOW_DEMO=1, and when CW_UI_PID is set they send
// only while that app is frontmost.
let uiEnv = ProcessInfo.processInfo.environment
let uiPid: pid_t? = uiEnv["CW_UI_PID"].flatMap { pid_t($0) }
let backgroundMode = uiPid != nil && uiEnv["CW_UI_MODE"] != "hid"
var useHID = !backgroundMode

func demoPid() -> pid_t? {
    (try? String(contentsOfFile: "/tmp/cw-demo.pid", encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

/// Why input must not go out right now, or nil. Typing calls it again before every character, since
/// another agent's app can come forward mid-text.
func inputRefusal() -> String? {
    // An empty or wrong CW_UI_PID once sent a test's clicks and keys to the real screen (2026-11-20).
    if let raw = uiEnv["CW_UI_PID"], uiPid == nil { return "refusing input: CW_UI_PID is set but '\(raw)' is not a pid" }
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let allowDemo = uiEnv["CW_UI_ALLOW_DEMO"] == "1"
    if !useHID, let pid = uiPid {
        if NSRunningApplication(processIdentifier: pid) == nil { return "refusing input: pid \(pid) is not running" }
        if !allowDemo, pid == demoPid() { return "refusing input: pid \(pid) is the user's demo app; set CW_UI_ALLOW_DEMO=1 to drive it on purpose" }
        return nil
    }
    if let want = uiPid, front != want {
        return "refusing input: pid \(want) is not frontmost (frontmost is \(front.map { String($0) } ?? "none"))"
    }
    if !allowDemo, let demo = demoPid(), front == demo {
        return "refusing input: the user's demo app (pid \(demo)) is frontmost; set CW_UI_ALLOW_DEMO=1 to drive it on purpose"
    }
    return nil
}

/// For input AppKit only takes from the real pointer or the frontmost app. In background mode it goes on in
/// HID mode when the app is already frontmost, since the caller then holds the screen, and stops otherwise.
func requireScreen(_ what: String) {
    guard !useHID, let pid = uiPid else { return }
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { useHID = true; return }
    FileHandle.standardError.write(Data("\(what) needs the screen lock: scripts/ui/screen-lock take <task>, then /tmp/cw-ui/front \(pid), then run this again\n".utf8))
    exit(4)
}

/// AppKit drops clicks and scrolls on a window of an inactive app. A test app started with `--background`
/// passes them on itself (App/Sources/MainWindow.swift), so warn when the target was started without it.
func warnUnlessBackgroundLaunch() {
    guard !useHID, let pid = uiPid else { return }
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-o", "args=", "-p", String(pid)]
    let pipe = Pipe()
    ps.standardOutput = pipe
    guard (try? ps.run()) != nil else { return }
    let args = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    ps.waitUntilExit()
    if !args.contains("--background"), NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
        FileHandle.standardError.write(Data("warning: pid \(pid) was not started with --background, so it ignores clicks and scrolls while another app is in front; relaunch it with scripts/run-app ... --background\n".utf8))
    }
}

func send(_ e: CGEvent?) {
    guard let e else { return }
    if useHID { e.post(tap: .cghidEventTap) } else { e.postToPid(uiPid!) }
}

/// A mouse event at a global point. In background mode AppKit needs the target window's number and a location
/// inside it, which only an NSEvent built for that window carries into its CGEvent.
func mouseEvent(_ type: CGEventType, at p: CGPoint, button: CGMouseButton = .left) -> CGEvent? {
    let kinds: [CGEventType: NSEvent.EventType] = [.mouseMoved: .mouseMoved, .leftMouseDown: .leftMouseDown, .leftMouseUp: .leftMouseUp,
        .rightMouseDown: .rightMouseDown, .rightMouseUp: .rightMouseUp, .leftMouseDragged: .leftMouseDragged]
    if !useHID, let pid = uiPid, let kind = kinds[type], let w = appWindows(pid).first(where: { $0.onscreen && $0.bounds.contains(p) }) {
        // AppKit turns the NSEvent's location into the CGEvent's flipped through the main display's height, and
        // back into window coordinates on arrival (measured 2026-11-20), so give it the point from the window's top.
        let local = NSPoint(x: p.x - w.bounds.minX, y: CGDisplayBounds(CGMainDisplayID()).height - (p.y - w.bounds.minY))
        let e = NSEvent.mouseEvent(with: kind, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: Int(w.id), context: nil, eventNumber: 0, clickCount: 1, pressure: 1)?.cgEvent
        if let e { stamp(e, at: p) }
        return e
    }
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
    if let e { stamp(e, at: p) }
    return e
}

/// In background mode, names the app's window under the point, front to back. AppKit reads it to pick the
/// window, since the window server never hit-tests an event posted to a pid.
func stamp(_ e: CGEvent, at p: CGPoint) {
    guard !useHID, let pid = uiPid, let w = appWindows(pid).first(where: { $0.onscreen && $0.bounds.contains(p) }) else { return }
    e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(w.id))
    e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(w.id))
    // Field 51 is the event's window number. AppKit drops a scroll posted to a pid without it (measured 2026-11-20).
    e.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(w.id))
}

if let why = inputRefusal() {
    FileHandle.standardError.write(Data((why + "\n").utf8))
    exit(3)
}
