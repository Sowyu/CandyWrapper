import AppKit
import Testing
import DesignSystem
@testable import Features

@MainActor @Suite(.fidelity)
struct WP717FidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "assistantSelectionToolbar": .init(0.065),
    ]
    @Test func assistantSelectionToolbar() throws {
        let repo = SidebarFidelityTests.repo
        let output = Fidelity.root.appendingPathComponent("wp717")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var differences: [(String, Double)] = []
        for tooLong in [false, true] {
            let name = tooLong ? "shorten" : "cite"
            for theme in ["light", "dark"] {
                let path = repo.appendingPathComponent("design/component-reference/wp717/\(name).rest.\(theme).png")
                let reference = try #require(NSBitmapImageRep(data: Data(contentsOf: path)))
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                let button = AssistantSelectionToolbar.button(tooLong: tooLong)
                button.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: button.intrinsicContentSize)
                canvas.addSubview(button)
                let image = Snapshot.image(of: canvas, size: NSSize(width: reference.pixelsWide / 2, height: reference.pixelsHigh / 2), scale: 2, dark: theme == "dark")
                let (difference, _, diff) = SidebarFidelityTests.compare(reference, image, bands: [])
                differences.append(("\(name).\(theme)", difference))
                try Snapshot.writePNG(image, to: output.appendingPathComponent("\(name).\(theme).png"))
                try Snapshot.writePNG(diff, to: output.appendingPathComponent("\(name).\(theme).diff.png"))
                print("WP717 \(name).\(theme): \(difference * 100)%")
            }
        }
        Self.ceilings.check("assistantSelectionToolbar", differences)
        let mean = differences.map(\.1).reduce(0, +) / Double(differences.count)
        print("FIDELITY WP717: \(differences.count) cases, mean \(mean * 100)%, worst \((differences.map(\.1).max() ?? 0) * 100)%")
        #expect(mean < 0.05)
    }
}
