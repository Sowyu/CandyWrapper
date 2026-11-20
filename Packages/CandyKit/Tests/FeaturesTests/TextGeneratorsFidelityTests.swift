import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// Settings > Providers > Text generators (4928) against T3's markup in Chromium (spec from
/// scripts/gen-text-generators-spec.py, references in design/component-reference/text-generators).
@MainActor @Suite(.fidelity)
struct TextGeneratorsFidelityTests {
    /// Per-case ceilings, measured 2026-11-19 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "textGenerators": .init(0.03),
    ]
    static let out = Fidelity.root.appendingPathComponent("text-generators")

    static func make(_ n: [String: String], size: NSSize) throws -> NSView {
        if n["kind"] == "service" {
            let grid = TextGeneratorServiceGrid(selected: "openai")
            let col = McpColumn([McpText("Service", size: 14, weight: .medium), grid], gap: 6)
            col.frame = NSRect(x: 0, y: 0, width: size.width, height: col.height(forWidth: size.width))
            col.layoutSubtreeIfNeeded()
            return col
        }
        let generators: [String: JSONValue] = n["kind"] == "rows" ? [
            "openrouter": TextGenerators.Config(kind: "openaiCompatible", baseUrl: "https://openrouter.ai/api/v1").json,
            "zollama": TextGenerators.Config(kind: "openaiCompatible", baseUrl: "http://localhost:11434/v1", enabled: false).json,
        ] : [:]
        let fake = TextGeneratorsTests.Fake(generators)
        let section = TextGeneratorsSection(context: fake.context)
        let env = fake.context.scope.environments[0]
        section.update(env, settings: env.settings!)
        return SettingsPages2FidelityTests.sized(section.section, size)
    }

    @Test func textGenerators() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/text-generators")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/text-generators.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String]
            let css = manifest[name]!
            let size = NSSize(width: css["width"]!, height: css["height"]!)
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let canvas = ConnectionsFidelityTests.Canvas(frame: .zero)
                let view = try Self.make(native, size: size)
                view.frame.origin = NSPoint(x: 8, y: 8)
                canvas.addSubview(view)
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='text-generators/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("text-generators", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("textGenerators", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY text-generators: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Text generators</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-text-generators.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.08)
    }
}
