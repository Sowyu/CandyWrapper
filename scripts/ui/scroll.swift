// Scrolls at a global point (points, top-left origin). Usage: scroll <x> <y> <dy pixels> [steps]
import CoreGraphics
import Foundation
let a = CommandLine.arguments
guard a.count >= 4, let x = Double(a[1]), let y = Double(a[2]), let dy = Int32(a[3]) else { print("usage"); exit(2) }
let steps = a.count > 4 ? Int(a[4]) ?? 1 : 1
let p = CGPoint(x: x, y: y)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(50_000)
for _ in 0..<steps {
    let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
    e?.location = p
    e?.post(tap: .cghidEventTap)
    usleep(16_000)
}
print("scrolled", dy, "x", steps)
