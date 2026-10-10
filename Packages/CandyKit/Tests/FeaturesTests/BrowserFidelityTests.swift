import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The browser's chrome row, empty states, unreachable page and Search project contents against
/// T3's markup in Chromium (spec from scripts/gen-browser-spec.py, references in
/// design/component-reference/browser). Writes ref, ours and diff PNGs plus report-browser.html to
/// /tmp/candywrapper-fidelity.
@MainActor
struct BrowserFidelityTests {
    static let out = URL(fileURLWithPath: "/tmp/candywrapper-fidelity/browser")

    static func view(_ name: String, size: CGSize) -> NSView {
        let frame = NSRect(x: 8, y: 8, width: size.width, height: size.height)
        switch name {
        case "chrome":
            let row = BrowserChromeRowView(frame: frame)
            row.url = "http://localhost:47420/"
            row.canGoBack = true
            row.refreshDisabled = false
            row.onPictureInPicture = {}
            row.onMore = { _ in }
            return row
        case "empty":
            return BrowserEmptyStateView(frame: frame)
        case "lists":
            let empty = BrowserEmptyStateView(frame: frame)
            empty.apply(recents: [.init(url: "http://localhost:47420/", title: "Candy test page", visited: "5m ago"),
                                  .init(url: "https://example.com/docs", title: nil, visited: "2h ago")],
                        servers: [PreviewableServer(server: DiscoveredLocalServer(host: "localhost", port: 47420, url: "http://localhost:47420", processName: "Python"),
                                                    source: .scanner, requestedUrl: "http://localhost:47420"),
                                  PreviewableServer(server: DiscoveredLocalServer(host: "localhost", port: 5173, url: "http://localhost:5173"),
                                                    source: .scanner, requestedUrl: "http://localhost:5173")])
            return empty
        case "unreachable":
            let page = BrowserUnreachableView(frame: frame)
            page.content = .failed(url: "http://localhost:47421/", code: -102, description: "ERR_CONNECTION_REFUSED")
            return page
        default:
            let body = ContentSearchView()
            func m(_ path: String, _ n: Int, _ line: String) -> ProjectContentMatch {
                let start = (line as NSString).range(of: "notes").location
                return ProjectContentMatch(path: path, lineNumber: n, lineContent: line, matchRanges: [.init(start: start, end: start + 5)])
            }
            body.apply(matches: [m("docs/notes.txt", 1, "Release notes for the demo"), m("docs/notes.txt", 4, "See the notes folder."),
                                 m("todo.txt", 2, "- write notes")],
                       status: .results(count: 3, truncated: false, files: 2), empty: "No results found.")
            let palette = CommandPaletteView(content: .custom(body))
            palette.inputAccessory = body.accessory
            palette.input.placeholder = "Search in demo-repo"
            palette.input.text = "notes"
            palette.footerActionLabel = "Open file"
            palette.escapeLabel = "Back"
            palette.frame = frame
            return palette
        }
    }

    @Test func browser() async throws {
        let repo = SidebarFidelityTests.repo
        let refDir = repo.appendingPathComponent("design/component-reference/browser")
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("design/component-reference/browser.json"))) as! [String: Any]
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
                    + ["ref", "ours", "diff"].map { "<img style='zoom:.5' src='browser/\(base).\($0).png'>" }.joined() + "</p>"
            }
        }
        for (base, total) in lines.sorted(by: { $0.1 > $1.1 }) { print("browser", base, String(format: "%.2f%%", total * 100)) }
        let mean = lines.map(\.1).reduce(0, +) / Double(max(1, lines.count))
        print(String(format: "FIDELITY browser: %d cases, mean differing %.2f%%", lines.count, mean * 100))
        let html = "<!doctype html><meta charset=utf-8><title>Browser</title><body style='font:13px -apple-system'>" + images
        try html.write(to: Self.out.deletingLastPathComponent().appendingPathComponent("report-browser.html"), atomically: true, encoding: .utf8)
        #expect(mean < 0.05)
    }
}
