// Types text into the frontmost app, then optionally presses Return. Usage: type <text> [--return]
import CoreGraphics
import Foundation
let a = CommandLine.arguments
guard a.count >= 2 else { print("usage: type <text> [--return]"); exit(2) }
let src = CGEventSource(stateID: .hidSystemState)
for scalar in a[1].utf16 {
    var unit = scalar
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
        e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        e.post(tap: .cghidEventTap)
    }
    usleep(8000)
}
// Return as its own key with "\r" attached; posted bare right after the text, it sometimes never arrived.
if a.contains("--return") {
    usleep(50000)
    var cr: UniChar = 13
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: down)!
        e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &cr)
        e.post(tap: .cghidEventTap)
        usleep(20000)
    }
}
