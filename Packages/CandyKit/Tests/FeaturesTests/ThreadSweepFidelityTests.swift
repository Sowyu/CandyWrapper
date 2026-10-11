import AppKit
import Testing
import DesignSystem
@testable import Features

@MainActor
struct ThreadSweepFidelityTests {
    @Test func threadSweepStates() throws {
        let repo = SidebarFidelityTests.repo
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/thread-sweep.json"))) as! [String: Any]
        let out = repo.appendingPathComponent(".thread-sweep-fidelity")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var errors: [Double] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, n = c["native"] as! [String: Any]
            for theme in ["light", "dark"] {
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: repo.appendingPathComponent("design/component-reference/thread-sweep/\(name).rest.\(theme).png"))))
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                let view: NSView
                if n["kind"] as? String == "task" {
                    let state = n["state"] as! String
                    let row = ThreadTaskStepView(step: .init(text: n["text"] as! String, status: state, durationMs: state == "completed" ? 62_000 : nil))
                    row.frame = NSRect(x: 8, y: 8, width: 300, height: row.height(forWidth: 300)); view = row
                } else {
                    let toast = ToastView(title: "Permissions have changed for Sandbox", message: "Pair again using a new link with the permissions you need.", actionTitle: "Open Connections", secondaryTitle: "Dismiss")
                    toast.frame = NSRect(x: 8, y: 8, width: 360, height: toast.height(forWidth: 360)); view = toast
                }
                canvas.addSubview(view)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2), scale: 2, dark: theme == "dark")
                let (error, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                errors.append(error)
                try Snapshot.writePNG(ours, to: out.appendingPathComponent("\(name).\(theme).png"))
                try Snapshot.writePNG(diff, to: out.appendingPathComponent("\(name).\(theme).diff.png"))
                print("thread-sweep \(name).\(theme): \(String(format: "%.2f", error * 100))%")
            }
        }
        let mean = errors.reduce(0, +) / Double(errors.count)
        print("FIDELITY thread-sweep: \(errors.count) cases, mean \(String(format: "%.2f", mean * 100))%, worst \(String(format: "%.2f", (errors.max() ?? 0) * 100))%")
        #expect(mean < 0.05)
    }
}
