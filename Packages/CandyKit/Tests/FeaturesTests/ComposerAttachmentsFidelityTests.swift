import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The image shelf, the expanded image preview, the stash menu and the stash badge against T3's
/// markup in Chromium (spec from scripts/gen-composer-attachments-spec.py, references in
/// design/component-reference/composer-attachments). Writes ref, ours and diff PNGs plus
/// report-composer-attachments.html to `Fidelity.root`.
@MainActor @Suite(.fidelity)
struct ComposerAttachmentsFidelityTests {
    /// Per-case ceilings, measured 2026-10-22 plus margin (FidelitySupport.swift).
    static let ceilings: FidelityCeilings = [
        "composerAttachments": .init(0.07),
    ]
    static let out = Fidelity.root.appendingPathComponent("composer-attachments")
    static var fixture: URL { SidebarFidelityTests.repo.appendingPathComponent("design/component-reference/composer-attachments-fixture.png") }

    /// 2026-10-10 12:00 UTC; the entries are 5 minutes and 2 hours older.
    static let now: Int64 = 1_791_633_600_000
    static func iso(_ ms: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func view(_ name: String, size: CGSize) -> NSView {
        switch name {
        case "shelf":
            let shelf = ComposerImageShelfView()
            shelf.tiles = [
                .init(id: "a", name: "a.png", status: .ready, fileURL: fixture),
                .init(id: "b", name: "b.png", status: .uploading(0.42), fileURL: fixture),
                .init(id: "c", name: "c.png", status: .failed("Upload failed"), fileURL: fixture),
            ]
            shelf.frame = NSRect(x: 8, y: 8, width: size.width, height: shelf.preferredHeight(width: size.width) - ComposerImageShelfView.marginBottom)
            return shelf
        case "preview":
            let url = fixture
            let load: AsyncImageView.Loader = { side in await ComposerImageIO.thumbnail(url, side: side, cover: false) }
            let preview = ExpandedImagePreviewView(items: [.init(key: "1", name: "screenshot.png", load: load),
                                                           .init(key: "2", name: "other.png", load: load)], index: 0)
            preview.frame = NSRect(x: 8, y: 8, width: size.width, height: size.height)
            return preview
        case "stash-badge":
            let badge = ComposerStashBadgeView()
            badge.count = 3
            badge.frame = NSRect(x: 8, y: 8, width: badge.preferredWidth, height: badge.preferredHeight)
            return badge
        default:
            let menu = ComposerStashMenuView()
            menu.nowMs = { now }
            menu.imageURL = { _ in fixture }
            menu.shortcutLabel = "⌘S"
            if name == "stash-menu" {
                let image = PromptStashEntry.Image(id: "i", name: "a.png", mimeType: "image/png", sizeBytes: 1, file: "f")
                menu.entries = [
                    PromptStashEntry(id: "1", createdAt: iso(now - 5 * 60_000), prompt: "Refactor the upload queue so retries keep their place",
                                     attachments: [image, image]),
                    PromptStashEntry(id: "2", createdAt: iso(now - 2 * 3_600_000), prompt: "",
                                     files: [.init(id: "f", name: "a.txt", mimeType: "text/plain", sizeBytes: 1, attachmentId: "u", environmentId: "e")]),
                ]
            }
            menu.frame = NSRect(x: 8, y: 8, width: size.width, height: menu.preferredHeight())
            return menu
        }
    }

    @Test func composerAttachments() async throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/composer-attachments")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/composer-attachments.json"))) as! [String: Any]
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
                if name.hasPrefix("stash") { #expect(abs(view.frame.height - CGFloat(css["height"]!)) < 0.5, "\(name) height") }
                canvas.addSubview(view)
                canvas.frame = NSRect(x: 0, y: 0, width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                view.layoutSubtreeIfNeeded()
                await AsyncImageView.loadAll(in: view)
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
                let ours = Snapshot.image(of: canvas, size: NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2),
                                          scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='composer-attachments/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("composer-attachments", base, String(format: "%.2f%%", total * 100)) }
        Self.ceilings.check("composerAttachments", lines)
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY composer-attachments: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Composer attachments</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-composer-attachments.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }
}
