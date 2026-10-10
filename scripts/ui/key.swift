// Sends a key with modifiers to the frontmost app. Usage: key <char> [cmd,opt,shift,ctrl]
import CoreGraphics
import Foundation
let a = CommandLine.arguments
let codes: [String: CGKeyCode] = ["l": 37, "d": 2, "end": 119, "home": 115, "return": 36, "escape": 53, "m": 46, "e": 14, "a": 0, "v": 9, "z": 6, "c": 8, "x": 7, "delete": 51]
guard a.count >= 2, let code = codes[a[1]] else { print("usage"); exit(2) }
var flags: CGEventFlags = []
for m in (a.count > 2 ? a[2] : "").split(separator: ",") {
    switch m { case "cmd": flags.insert(.maskCommand); case "opt": flags.insert(.maskAlternate)
    case "shift": flags.insert(.maskShift); case "ctrl": flags.insert(.maskControl); default: break }
}
for down in [true, false] {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
    e?.flags = flags
    e?.post(tap: .cghidEventTap)
    usleep(30_000)
}
print("key", a[1], a.count > 2 ? a[2] : "")
