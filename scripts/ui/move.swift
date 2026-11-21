// Moves the pointer without clicking, for hover timing. Global screen points, top-left origin.
// Usage: move <x> <y>, or move <x1> <y1> <x2> <y2> <ms> to glide from one point to the other in 60 Hz steps.
import CoreGraphics
import Foundation
requireScreen("hover")  // AppKit follows the real pointer for this; posted events do nothing in the background
let a = CommandLine.arguments.dropFirst().compactMap(Double.init)
func post(_ p: CGPoint) { send(mouseEvent(.mouseMoved, at: p)) }
switch a.count {
case 2: post(CGPoint(x: a[0], y: a[1]))
case 5:
    let steps = max(1, Int(a[4] / 16.7))
    for i in 0...steps {
        let t = Double(i) / Double(steps)
        post(CGPoint(x: a[0] + (a[2] - a[0]) * t, y: a[1] + (a[3] - a[1]) * t))
        usleep(16_700)
    }
default: print("usage: move x y | move x1 y1 x2 y2 ms"); exit(2)
}
