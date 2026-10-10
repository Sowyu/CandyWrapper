import AppKit

// Prepended by scripts/ui/build to the tools that post input (click, scroll, key, type). HID events
// go to whatever app is frontmost, and agents share the screen with the user's demo app: a stray
// keystroke once landed in the user's real composer. So these tools refuse to send input while the
// demo app (pid in /tmp/cw-demo.pid) is frontmost unless CW_UI_ALLOW_DEMO=1, and when CW_UI_PID is
// set they send only while that app is frontmost.
do {
    let env = ProcessInfo.processInfo.environment
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    if let want = env["CW_UI_PID"].flatMap({ Int32($0) }), front != want {
        FileHandle.standardError.write(Data("refusing input: pid \(want) is not frontmost (frontmost is \(front.map { String($0) } ?? "none"))\n".utf8))
        exit(3)
    }
    if env["CW_UI_ALLOW_DEMO"] != "1",
       let text = try? String(contentsOfFile: "/tmp/cw-demo.pid", encoding: .utf8),
       let demo = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), front == demo {
        FileHandle.standardError.write(Data("refusing input: the user's demo app (pid \(demo)) is frontmost; set CW_UI_ALLOW_DEMO=1 to drive it on purpose\n".utf8))
        exit(3)
    }
}
