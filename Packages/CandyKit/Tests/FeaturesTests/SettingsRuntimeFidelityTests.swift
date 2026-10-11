import AppKit
import Testing
@testable import Features
import DesignSystem
import T3Protocol

@MainActor struct SettingsRuntimeFidelityTests {
    @Test func settingsRuntime() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/settings-runtime")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/settings-runtime.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        var totals: [Double] = []
        let out = repo.appendingPathComponent(".wp713b-fidelity")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, kind = (c["native"] as! [String: String])["kind"]!
            let size = NSSize(width: manifest[name]!["width"]!, height: manifest[name]!["height"]!)
            for theme in ["light", "dark"] {
                defer { FontRuntime.apply(.init()) }
                var fonts = FontRuntimeInput()
                if kind == "custom" { fonts.interfaceFamily = "Menlo"; fonts.interfaceSize = 20; fonts.codeSize = 16 }
                FontRuntime.apply(fonts)
                let view: NSView
                if kind == "telemetry" {
                    let buckets: [JSONValue] = [(0.0,0.0,0.0),(12,60,20),(60,30,10),(30,10,70),(3,1,0)].map {
                        .object(["avgCpuPercent": .number($0.0), "maxCpuPercent": .number($0.0), "ioReadBytes": .number($0.1), "ioWriteBytes": .number($0.2)])
                    }
                    view = SettingsResourceHistoryChartView(buckets: buckets)
                } else {
                    let box = DSView()
                    let ui = LabelView("The quick brown fox 0O 1lI", font: DSFont.ui(14)); ui.lineHeight = 24
                    let code = LabelView("let value = 42;", font: DSFont.mono(13)); code.lineHeight = 24
                    box.addSubview(ui); box.addSubview(code)
                    ui.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
                    code.frame = NSRect(x: 0, y: 24, width: 360, height: 24)
                    view = box
                }
                view.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: size)
                let canvas = ConnectionsFidelityTests.Canvas(frame: .zero); canvas.addSubview(view)
                let base = "\(name).rest.\(theme)"
                let reference = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent(base + ".png"))))
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(reference.pixelsWide) / 2, height: CGFloat(reference.pixelsHigh) / 2), scale: 2, dark: theme == "dark")
                let (difference, _, diff) = SidebarFidelityTests.compare(reference, ours, bands: [])
                totals.append(difference)
                try Snapshot.writePNG(ours, to: out.appendingPathComponent(base + ".ours.png"))
                try Snapshot.writePNG(diff, to: out.appendingPathComponent(base + ".diff.png"))
                print(String(format: "settings-runtime %@ %.2f%%", base, difference * 100))
            }
        }
        let mean = totals.reduce(0, +) / Double(totals.count)
        print(String(format: "FIDELITY settings-runtime: %d cases, mean differing %.2f%%", totals.count, mean * 100))
        #expect(mean < 0.08)
    }
}
