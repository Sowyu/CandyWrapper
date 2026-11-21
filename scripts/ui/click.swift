// Clicks at a global point in screen points (top-left origin).
// Usage: click <x> <y> [right] [double] [cmd,opt,shift,ctrl]
import CoreGraphics
import Foundation
warnUnlessBackgroundLaunch()
let a = CommandLine.arguments
guard a.count >= 3, let x = Double(a[1]), let y = Double(a[2]) else { print("usage: click x y [right] [double] [cmd,opt,shift,ctrl]"); exit(2) }
let words = Set(a.dropFirst(3).flatMap { $0.split(separator: ",").map(String.init) })
let masks: [String: CGEventFlags] = ["cmd": .maskCommand, "opt": .maskAlternate, "shift": .maskShift, "ctrl": .maskControl]
let flags = CGEventFlags(words.compactMap { masks[$0] })
let right = words.contains("right")
let (down, up): (CGEventType, CGEventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
let p = CGPoint(x: x, y: y)
send(mouseEvent(.mouseMoved, at: p))
usleep(60_000)
for n in 1...(words.contains("double") ? 2 : 1) {
    for type in [down, up] {
        let e = mouseEvent(type, at: p, button: right ? .right : .left)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
        e?.flags = flags
        send(e)
        usleep(n == 1 && type == up ? 90_000 : 40_000)
    }
}
print("clicked", x, y, words.sorted().joined(separator: " "))
