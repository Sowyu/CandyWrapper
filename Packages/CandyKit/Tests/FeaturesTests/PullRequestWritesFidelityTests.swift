import AppKit
import Testing
import DesignSystem
@testable import T3Protocol
import T3Store
@testable import Features

/// WP7.5c's popups against T3's markup in Chromium: the checks popover, the composer's review form and a
/// pull request link's preview card (spec from scripts/gen-pull-request-writes-spec.py, references in
/// design/component-reference/pull-request-writes). Writes ref, ours and diff PNGs plus
/// report-pull-request-writes.html to /tmp/candywrapper-fidelity.
@MainActor
struct PullRequestWritesFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/pull-request-writes")
    static let nowMs = T3Timestamp.parseEpochMs("2026-10-10T16:00:00Z")!

    static func view(_ name: String, size: CGSize) throws -> NSView {
        let frame = NSRect(x: 8, y: 8, width: size.width, height: size.height)
        let view: NSView
        switch name {
        case "checks-popover":
            let checks = [PullRequestCheck(name: "Unit tests", status: "success", url: "https://github.com/o/r/actions/runs/1"),
                          PullRequestCheck(name: "Typecheck", status: "failure", url: "https://github.com/o/r/actions/runs/2"),
                          PullRequestCheck(name: "Deploy preview", status: "skipped")]
            let content = PullRequestChecksPopoverView(checksState: "failing", summary: PullRequestDetailLogic.summarizeChecks(checks), body: .checks(checks))
            view = PopoverView(content: content, width: .md)
        case "review-form":
            var d = try PullRequestFixtures.detail()
            d.state = "open"
            let store = PullRequestReviewStore()
            store.setSummary("k", "Looks good overall, two nits inline.")
            let composer = PullRequestComposerView(detail: d, reviewKey: "k", store: store)
            view = PopoverView(content: composer, width: .lg)
        default:
            var d = try PullRequestFixtures.detail()
            d.state = "open"; d.mergedAt = nil; d.closedAt = nil
            view = PullRequestLinkPreviewView(detail: d, nowMs: nowMs)
        }
        view.frame = frame
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func pullRequestWrites() throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/pull-request-writes")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/pull-request-writes.json"))) as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: refDir.appendingPathComponent("manifest.json"))) as! [String: [String: Double]]
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lines: [(String, Double)] = [], images = ""
        for c in spec["cases"] as! [[String: Any]] {
            let name = c["name"] as! String
            let css = manifest[name]!
            for theme in spec["themes"] as! [String] {
                let base = "\(name).rest.\(theme)"
                let ref = try #require(NSBitmapImageRep(data: Data(contentsOf: refDir.appendingPathComponent("\(base).png"))))
                let size = NSSize(width: CGFloat(ref.pixelsWide) / 2, height: CGFloat(ref.pixelsHigh) / 2)
                let canvas = SidebarSearchFidelityTests.Canvas(frame: NSRect(origin: .zero, size: size))
                canvas.addSubview(try Self.view(name, size: CGSize(width: css["width"]!, height: css["height"]!)))
                let ours = Snapshot.image(of: canvas, size: size, scale: 2, dark: theme == "dark")
                let (total, _, diff) = SidebarFidelityTests.compare(ref, ours, bands: [])
                try ref.representation(using: .png, properties: [:])!.write(to: Self.out.appendingPathComponent("\(base).ref.png"))
                try Snapshot.writePNG(ours, to: Self.out.appendingPathComponent("\(base).ours.png"))
                try Snapshot.writePNG(diff, to: Self.out.appendingPathComponent("\(base).diff.png"))
                lines.append((base, total))
                images += "<p>\(base): \(String(format: "%.2f", total * 100))%<br>"
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='pull-request-writes/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("pull-request-writes", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY pull-request-writes: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Pull request writes</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-pull-request-writes.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }
}
