// Scrolls at a global point (points, top-left origin). Usage: scroll <x> <y> <dy pixels> [steps]
import CoreGraphics
import Foundation
warnUnlessBackgroundLaunch()
let a = CommandLine.arguments
guard a.count >= 4, let x = Double(a[1]), let y = Double(a[2]), let dy = Int32(a[3]) else { print("usage"); exit(2) }
let steps = a.count > 4 ? Int(a[4]) ?? 1 : 1
let p = CGPoint(x: x, y: y)
send(mouseEvent(.mouseMoved, at: p))
usleep(50_000)
for _ in 0..<steps {
    let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
    e?.location = p
    if let e { stamp(e, at: p) }
    send(e)
    usleep(16_000)
}
print("scrolled", dy, "x", steps)
