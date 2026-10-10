import AppKit
import Testing
import DesignSystem
import T3Store
@testable import Features

/// The right panel's tab strip, the surface launcher, the Files surface and a file tab's subheader
/// against T3's markup in Chromium (spec from scripts/gen-files-spec.py, references in
/// design/component-reference/files). Writes ref, ours and diff PNGs plus report-files.html to
/// /tmp/candywrapper-fidelity.
@MainActor
struct FilesFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/files")

    /// Clips the panel's left border off, as the reference has none.
    final class Clip: DSView {}

    static func view(_ name: String, size: CGSize) -> NSView {
        let frame = NSRect(x: 8, y: 8, width: size.width, height: size.height)
        switch name {
        case "tabs":
            let clip = Clip(frame: frame)
            clip.clipsToBounds = true
            let panel = RightPanelView(frame: NSRect(x: -1, y: 0, width: size.width + 1, height: size.height))
            var state = RightPanelState()
            state.open(.diff); state.openFile("src/answer.ts"); state.open(.files); state.activate("file:src/answer.ts")
            panel.apply(state)
            clip.addSubview(panel)
            return clip
        case "files":
            let files = FilesPanelView(frame: frame)
            var model = FileTreeModel()
            model.setChildren([ProjectEntry(path: "scratch", isDirectory: true), ProjectEntry(path: "src", isDirectory: true),
                               ProjectEntry(path: "hello.py", isDirectory: false), ProjectEntry(path: "notes.md", isDirectory: false),
                               ProjectEntry(path: "README.md", isDirectory: false)], of: "")
            _ = model.toggle("scratch")
            model.setChildren([ProjectEntry(path: "scratch/edit.swift", isDirectory: false), ProjectEntry(path: "scratch/notes.md", isDirectory: false)], of: "scratch")
            files.model = model
            return files
        case "file-header":
            let surface = FileSurfaceView(frame: frame)
            surface.projectName = "demo-repo"
            surface.explorerOpen = true
            surface.show(path: "src/answer.ts", revealLine: nil)
            surface.setContent(.text("", truncated: false, byteLength: 0, editable: true))
            return surface
        default:
            return SurfaceLauncherView(frame: frame)
        }
    }

    @Test func files() async throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/files")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/files.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let css = manifest[name]!
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let canvas = SidebarSearchFidelityTests.Canvas(frame: .zero)
                let view = Self.view(name, size: CGSize(width: css["width"]!, height: css["height"]!))
                canvas.addSubview(view)
                canvas.frame = NSRect(x: 0, y: 0, width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                view.layoutSubtreeIfNeeded()
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='files/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("files", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY files: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Files</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-files.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }
}
