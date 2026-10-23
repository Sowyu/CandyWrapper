// Drags with the left button from one global point to another in screen points (top-left origin), in small
// steps so AppKit sees a real drag. Usage: drag <x1> <y1> <x2> <y2> [steps] [hold-ms]
// hold-ms waits at the end before the release, so a screenshot can catch the drop line.
import CoreGraphics
import Foundation
let a = CommandLine.arguments
guard a.count >= 5, let x1 = Double(a[1]), let y1 = Double(a[2]), let x2 = Double(a[3]), let y2 = Double(a[4]) else {
    print("usage: drag x1 y1 x2 y2 [steps] [hold-ms]"); exit(2)
}
let steps = a.count > 5 ? max(2, Int(a[5]) ?? 20) : 20
let hold = a.count > 6 ? UInt32(a[6]) ?? 0 : 0
func post(_ type: CGEventType, _ p: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    if type == .leftMouseDown || type == .leftMouseUp { e?.setIntegerValueField(.mouseEventClickState, value: 1) }
    e?.post(tap: .cghidEventTap)
}
let start = CGPoint(x: x1, y: y1), end = CGPoint(x: x2, y: y2)
post(.mouseMoved, start); usleep(60_000)
post(.leftMouseDown, start); usleep(120_000)
for i in 1...steps {
    let t = Double(i) / Double(steps)
    post(.leftMouseDragged, CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t))
    usleep(25_000)
}
// A few still drags at the end, so the drag loop settles on the target.
for _ in 0..<4 { post(.leftMouseDragged, end); usleep(40_000) }
if hold > 0 { usleep(hold * 1000) }
post(.leftMouseUp, end)
print("dragged", x1, y1, "to", x2, y2)
