import AppKit
import Testing
import DesignSystem
@testable import Features

@MainActor
struct ThreadLeftoversFidelityTests {
    @Test func threadControls() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/thread-leftovers")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/thread-leftovers.json"))) as! [String: Any]
        let out = repo.appendingPathComponent(".wp710b-fidelity")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var differences: [Double] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, n = c["native"] as! [String: Any]
            for theme in ["light", "dark"] {
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(name).rest.\(theme).png"))))
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                let view: NSView
                if n["kind"] as? String == "find" {
                    let bar = ThreadFindBarView(frame: NSRect(x: 8, y: 8, width: 384, height: 36))
                    let query = n["query"] as! String
                    bar.input.text = query
                    bar.present(query: query, index: n["index"] as! Int, total: n["count"] as! Int, loading: n["loading"] as! Bool)
                    view = bar
                } else {
                    let meter = ThreadContextWindowMeterView(frame: NSRect(x: 8, y: 8, width: 28, height: 28))
                    meter.usage = ThreadContextWindowUsage(used: n["used"] as! Double, maximum: n["max"] as? Double, automatically: true)
                    view = meter
                }
                canvas.addSubview(view)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2), scale: 2, dark: theme == "dark")
                let (difference, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                differences.append(difference)
                try Snapshot.writePNG(ours, to: out.appendingPathComponent("\(name).\(theme).png"))
                try Snapshot.writePNG(diff, to: out.appendingPathComponent("\(name).\(theme).diff.png"))
                print("thread-leftovers \(name).\(theme): \(String(format: "%.2f", difference * 100))%")
            }
        }
        let mean = differences.reduce(0,+) / Double(differences.count)
        print("FIDELITY thread-leftovers: \(differences.count) cases, mean differing \(String(format: "%.2f", mean * 100))%")
        #expect(mean < 0.05)
    }
}
