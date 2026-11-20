import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The images a tool group opened at Nightly 4928 (scripts/gen-viewed-images-spec.py,
/// design/component-reference/viewed-images): two workspace images, one scaled to the 10rem cap, one at its size.
/// The row decodes the spec's own PNGs; their sizes are recorded first, as a signed asset URL reports them.
@MainActor @Suite(.fidelity)
struct ViewedImagesFidelityTests {
    /// Per-case ceilings, set 2026-11-19 in line with the user message media cases (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "viewedImages": .init(0.06),
    ]

    @Test func viewedImages() async throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/viewed-images")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/viewed-images.json"))) as! [String: Any]
        let out = Fidelity.root.appendingPathComponent("viewed-images")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = []
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String, native = c["native"] as! [String: String], html = c["html"] as! String
            let paths = native["paths"]!.split(separator: ",").map(String.init)
            let pngs = html.components(separatedBy: "src=\"data:image/png;base64,").dropFirst().map { Data(base64Encoded: String($0.prefix { $0 != "\"" }))! }
            let root = "/w/demo"
            var images: [String: CGImage] = [:]
            for (path, png) in zip(paths, pngs) {
                guard case .workspaceFile(let file) = MarkdownImageSource.classify(path, workspaceRoot: root) else { Issue.record("not a workspace file: \(path)"); return }
                let key = MarkdownImageSource.workspaceFile(file).key
                let image = NSBitmapImageRep(data: png)!.cgImage!
                images[key] = image
                MarkdownImages.record(CGSize(width: image.width, height: image.height), for: key)
            }
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let size = NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                let canvas = SidebarSearchFidelityTests.Canvas(frame: NSRect(origin: .zero, size: size))
                let model = ThreadViewModel()
                model.workspaceRoot = root
                let row = ViewedImagesRowView()
                row.context = TimelineContext()
                row.context.model = model
                row.configure(TimelineItem(row: TimelineRow(id: "g:viewed-images", createdAt: nil, kind: .viewedImages(paths: paths))))
                row.frame = NSRect(x: 8, y: 8, width: 640, height: row.height(forWidth: 640))
                canvas.addSubview(row)
                canvas.layoutSubtreeIfNeeded()
                // Each image decodes the spec's bytes instead of fetching the workspace file.
                for case let view as AsyncImageView in row.subviews {
                    let key = view.key, image = key.flatMap { images[$0] }
                    view.set(key: nil, fallbackText: "", loader: nil)
                    view.set(key: key, fallbackText: "", loader: { _ in image })
                }
                await AsyncImageView.loadAll(in: canvas)
                let ours = Snapshot.image(of: canvas, size: size, scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try Snapshot.writePNG(ours, to: out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                print("viewed-images \(base): \(String(format: "%.2f", total * 100))%, row height \(row.frame.height)")
                withExtendedLifetime(model) {}
            }
        }
        Self.ceilings.check("viewedImages", lines)
    }
}
