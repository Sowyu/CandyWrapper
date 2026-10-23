// Sends a key with modifiers to the frontmost app. Usage: key <char> [cmd,opt,shift,ctrl]
import CoreGraphics
import Foundation
let a = CommandLine.arguments
let codes: [String: CGKeyCode] = ["l": 37, "d": 2, "end": 119, "home": 115, "return": 36, "escape": 53, "m": 46, "e": 14, "a": 0, "v": 9, "z": 6, "c": 8, "x": 7, "delete": 51, "up": 126, "down": 125,
    "k": 40, "n": 45, "b": 11, "o": 31, "j": 38, "s": 1, "p": 35, "u": 32, "h": 4, "f": 3, "t": 17, "w": 13,
    "[": 33, "]": 30, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "tab": 48, "space": 49, "i": 34, "left": 123, "right": 124]
guard a.count >= 2, let code = codes[a[1]] else { print("usage"); exit(2) }
// Press the modifier keys like a keyboard: down one by one before the key, up in reverse after it.
// Posting only the key with flags set left those flags latched in the HID state, so the next click
// arrived as a Cmd+Shift click (a sidebar row joined the selection instead of opening) until any
// plain key reset it.
let modifiers: [String: (CGKeyCode, CGEventFlags)] = ["cmd": (55, .maskCommand), "opt": (58, .maskAlternate),
    "shift": (56, .maskShift), "ctrl": (59, .maskControl)]
let held = (a.count > 2 ? a[2] : "").split(separator: ",").compactMap { modifiers[String($0)] }
func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
    e?.flags = flags
    e?.post(tap: .cghidEventTap)
    usleep(30_000)
}
var flags: CGEventFlags = []
for (key, flag) in held { flags.insert(flag); post(key, down: true, flags: flags) }
post(code, down: true, flags: flags)
post(code, down: false, flags: flags)
for (key, flag) in held.reversed() { flags.remove(flag); post(key, down: false, flags: flags) }
// Self-check: no modifier may stay latched for the next click.
let latched = CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
if !latched.isEmpty { FileHandle.standardError.write(Data("modifiers still held after key: \(latched.rawValue)\n".utf8)); exit(1) }
print("key", a[1], a.count > 2 ? a[2] : "")
