import AppKit
import Testing
import T3Protocol
import DesignSystem
@testable import Features

@MainActor
struct OnboardingSnapShotFidelityTests {
    @Test func recoveryAndSourceDetails() throws {
        let repo = SidebarFidelityTests.repo
        let output = repo.appendingPathComponent("design/validation/wp716b")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var scores: [Double] = []
        for name in ["connection", "settings", "details"] {
            for theme in ["light", "dark"] {
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: repo.appendingPathComponent("design/component-reference/onboarding-snapshot/\(name).rest.\(theme).png"))))
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                if name == "details" {
                    let backdrop = DSView(frame: CGRect(x: 8, y: 8, width: 208, height: 60))
                    backdrop.layer?.backgroundColor = NSColor(srgbRed: 100/255, green: 116/255, blue: 139/255, alpha: 1).cgColor
                    let details = SnapShotAttachmentDetailsView(source: .object(["appName": .string("Editor"), "windowTitle": .string("")]))
                    details.frame = backdrop.bounds; backdrop.addSubview(details); canvas.addSubview(backdrop)
                } else {
                    let gate = FirstRunRecoveryView(frame: CGRect(x: 8, y: 8, width: 440, height: 300))
                    gate.reason = name == "connection" ? .connecting : .settings
                    canvas.addSubview(gate)
                }
                let ours = Snapshot.image(of: canvas, size: CGSize(width: CGFloat(ref.pixelsWide)/2, height: CGFloat(ref.pixelsHigh)/2), scale: 2, dark: theme == "dark")
                try Snapshot.writePNG(ours, to: output.appendingPathComponent("\(name).\(theme).png"))
                let (score, _, _) = SidebarFidelityTests.compare(ref, ours, bands: [])
                scores.append(score)
                print(String(format: "FIDELITY onboarding-snapshot %@.%@: %.2f%%", name, theme, score * 100))
            }
        }
        let mean = scores.reduce(0, +) / Double(scores.count)
        print(String(format: "FIDELITY onboarding-snapshot mean: %.2f%%", mean * 100))
        #expect(mean < 0.03)
    }
}
