// Mean brightness per column of a PNG over rows [y0, y1), printing where it steps. Usage: colmean <png> <y0> <y1> <x0> <x1>
import AppKit
let a = CommandLine.arguments
let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: a[1])))!
let y0 = Int(a[2])!, y1 = Int(a[3])!, x0 = Int(a[4])!, x1 = Int(a[5])!
var means: [Double] = []
for x in x0..<x1 {
    var vals: [Double] = []
    for y in stride(from: y0, to: y1, by: 2) {
        let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        vals.append(Double(c.redComponent + c.greenComponent + c.blueComponent) / 3 * 255)
    }
    vals.sort()
    means.append(vals[vals.count / 2])  // median ignores text
}
var last = means[0]
for (i, m) in means.enumerated() where abs(m - last) >= 1.5 { print("x=\(x0 + i) median \(String(format: "%.1f", last)) -> \(String(format: "%.1f", m))"); last = m }
print("first", String(format: "%.1f", means.first!), "last", String(format: "%.1f", means.last!))
