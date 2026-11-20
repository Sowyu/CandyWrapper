import AppKit
import Testing
import DesignSystem
@testable import Features

/// A question option's Markdown preview at `text-xs text-foreground/70` against T3's ChatMarkdown in Chromium
/// (spec from scripts/gen-question-preview-spec.py, references in design/component-reference/question-option-preview).
@MainActor @Suite(.fidelity)
struct QuestionPreviewMarkdownFidelityTests {
    /// Glyph antialiasing only (measured 2026-11-19 at 3.6% to 4.7%); the Markdown suite's ceiling.
    static let ceilings: FidelityCeilings = ["questionPreview": .init(0.055)]

    @Test func questionPreview() throws {
        let repo = MarkdownFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/question-option-preview")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/question-option-preview.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        let dir = Fidelity.root.appendingPathComponent("question-option-preview")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var cases: [(String, Double)] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let native = c["native"] as! [String: String]
            let width = CGFloat(Double(native["width"]!)!)
            for theme in ["light", "dark"] {
                let file = "\(name).rest.\(theme).png"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent(file))))
                let canvas = MarkdownFidelityTests.Canvas(frame: .zero)
                canvas.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                let view = MarkdownView(frame: .zero)
                view.body = .xs
                view.bodyColor = Themed.color(\.foreground, 0.7)
                view.setMarkdown(native["markdown"]!, preservesLineBreaks: true)
                let height = view.height(forWidth: width)
                canvas.addSubview(view)
                view.frame = NSRect(x: 8, y: 8, width: width, height: height)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (share, diff) = MarkdownFidelityTests.compare(ref, ours)
                let base = "\(name).\(theme)"
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(base).ref.png"))
                try FileManager.default.copyItem(at: refDir.appendingPathComponent(file), to: dir.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: dir.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: dir.appendingPathComponent("\(base).diff.png"))
                print(String(format: "QUESTION-PREVIEW %@ %@: %.2f%% differ, height ref %.2f ours %.2f", name, theme, share * 100, manifest[name]?["height"] ?? 0, height))
                #expect(abs(height - CGFloat(manifest[name]?["height"] ?? 0)) <= 1, "\(base) height")
                cases.append((base, share))
            }
        }
        Self.ceilings.check("questionPreview", cases)
    }
}
