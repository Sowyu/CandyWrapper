import AppKit
import Testing
import DesignSystem
@testable import Features

@MainActor
struct DesktopLeftoversFidelityTests {
    @Test func copyAndWizardStates() throws {
        let repo = SidebarFidelityTests.repo
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("design/validation/wp716"), withIntermediateDirectories: true)
        let references = repo.appendingPathComponent("design/component-reference/desktop-leftovers")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/desktop-leftovers.json"))) as! [String: Any]
        var scores: [Double] = []
        for item in spec["cases"] as! [[String: Any]] {
            let name = item["name"] as! String, native = item["native"] as! [String: String]
            for theme in ["light", "dark"] {
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: references.appendingPathComponent("\(name).rest.\(theme).png"))))
                let view: NSView
                if native["kind"] == "copy" { view = AnchoredCopyToastView(native["text"]!) }
                else { view = WizardStepsView(steps: ["Connect", "Agents", "Projects"], currentStep: Int(native["step"]!)!) }
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                view.frame = NSRect(x: 8, y: 8, width: native["kind"] == "copy" ? view.intrinsicContentSize.width : 528,
                                    height: native["kind"] == "copy" ? 26 : 44)
                canvas.addSubview(view)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2), scale: 2, dark: theme == "dark")
                try Snapshot.writePNG(ours, to: repo.appendingPathComponent("design/validation/wp716/\(name).\(theme).png"))
                let (score, _, _) = SidebarFidelityTests.compare(ref, ours, bands: [])
                scores.append(score)
                print(String(format: "FIDELITY desktop-leftovers %@.%@: %.2f%%", name, theme, score * 100))
            }
        }
        let mean = scores.reduce(0, +) / Double(scores.count)
        print(String(format: "FIDELITY desktop-leftovers mean: %.2f%%", mean * 100))
        #expect(mean < 0.04)
    }
}
