import AppKit
import Testing
import DesignSystem
import T3Protocol
@testable import Features

/// The Environments map's toolbar and footer and its details panel (5258) against T3's markup in Chromium (spec from
/// scripts/gen-environments-map-spec.py, references in design/component-reference/environments-map). The scene
/// between toolbar and footer has no reference yet.
@MainActor @Suite(.fidelity)
struct EnvironmentsMapFidelityTests {
    /// Per-case ceilings, measured 2026-11-25 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "environmentsMap": .init(0.035),
    ]
    static let out = Fidelity.root.appendingPathComponent("environments-map")

    static func make(_ n: [String: String], size: NSSize) throws -> NSView {
        let T = EnvironmentsMapLogicTests.self
        let map = EnvironmentsMapView(frame: NSRect(x: 0, y: 0, width: size.width, height: 400))
        map.set(EnvironmentsMapModel(clientLabel: "This device", environments: EnvironmentsMapViewTests.inputs("shared"), now: T.now))
        map.frame.size.height = map.height(forWidth: size.width)
        map.layoutSubtreeIfNeeded()
        switch n["kind"] {
        case "toolbar", "footer":
            // The part T3 draws as its own element, cut from the whole map.
            let box = DSView(frame: NSRect(origin: .zero, size: size))
            box.wantsLayer = true
            box.layer?.masksToBounds = true
            map.frame.origin.y = n["kind"] == "toolbar" ? 0 : -(map.frame.height - size.height)
            box.addSubview(map)
            return box
        default:
            let details = map.details
            if n["kind"] == "link" {
                let edge = try #require(map.canvas.graph.links.first { $0.from == fleetEnvironmentNodeId("nucbox") && $0.link?.environmentId == "fs-3" })
                map.canvas.state.selection = .edge(edge.id)
            }
            details.removeFromSuperview()
            details.frame = NSRect(x: 0, y: 0, width: size.width, height: details.height(forWidth: size.width))
            details.layoutSubtreeIfNeeded()
            return details
        }
    }

    @Test func environmentsMap() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/environments-map")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/environments-map.json"))) as! [String: Any]
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
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='environments-map/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("environments-map", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("environmentsMap", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY environments-map: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Environments map</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-environments-map.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.08)
    }
}
