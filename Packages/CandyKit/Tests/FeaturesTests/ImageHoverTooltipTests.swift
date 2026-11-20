import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// The user asked on 2026-11-21 that hovering an image in a thread show no path tooltip. T3 shows the path or URL
/// in a code tooltip (MediaActions.tsx:248-276); here no thread image has one, and each keeps its accessibility label.
@MainActor @Suite struct ImageHoverTooltipTests {
    static func images(in view: NSView) -> [AsyncImageView] {
        view.subviews.flatMap { ($0 as? AsyncImageView).map { [$0] } ?? images(in: $0) }
    }

    static func expectNoTooltip(_ views: [NSView], _ where_: String) {
        #expect(!views.isEmpty, "\(where_): no image views")
        for view in views {
            #expect(view.toolTip == nil, "\(where_): toolTip \(view.toolTip ?? "")")
            #expect(!view.trackingAreas.contains { $0.owner is TooltipController }, "\(where_): tooltip controller")
        }
    }

    @Test func viewedImagesRowHasNoPathTooltip() {
        let model = ThreadViewModel()
        model.workspaceRoot = "/w/demo"
        let row = ViewedImagesRowView()
        row.context = TimelineContext()
        row.context.model = model
        row.configure(TimelineItem(row: TimelineRow(id: "g:viewed-images", createdAt: nil, kind: .viewedImages(paths: ["/w/demo/a.png"]))))
        row.frame = NSRect(x: 0, y: 0, width: 640, height: row.height(forWidth: 640))
        row.layoutSubtreeIfNeeded()
        let views = Self.images(in: row)
        Self.expectNoTooltip(views, "viewed images row")
        #expect(views.allSatisfy { $0.accessibilityLabel()?.hasPrefix("Preview ") == true })
        withExtendedLifetime(model) {}
    }

    @Test func openToolRowImageHasNoPathTooltip() {
        let path = "/tmp/demo-repo/viewed-\(UUID().uuidString).png"
        let e = WorkLogEntry(id: "r", createdAt: T3Timestamp("2026-10-12T00:00:00.000Z"), label: "Read", detail: path,
                             tone: .tool, viewedImagePath: path, requestKind: "file-read", itemType: .dynamicTool)
        let view = WorkDetailView()
        view.detail = WorkDetail.of(e, label: "Read", workspaceRoot: "/tmp/demo-repo")
        view.frame = NSRect(x: 0, y: 0, width: 600, height: view.height(forWidth: 600))
        view.layoutSubtreeIfNeeded()
        Self.expectNoTooltip(Self.images(in: view), "tool row")
    }

    @Test func markdownImageHasNoPathOrURLTooltip() {
        let view = MarkdownView(frame: NSRect(x: 0, y: 0, width: 680, height: 400))
        view.cwd = "/w/demo"
        view.setMarkdown("![shot](/w/demo/shot.png)\n\n![web](https://example.com/a.png)")
        view.frame.size.height = view.height(forWidth: 680)
        view.layoutSubtreeIfNeeded()
        let views = Self.images(in: view)
        #expect(views.count == 2)
        Self.expectNoTooltip(views, "markdown")
    }

    @Test func galleryTilesAndLargePictureHaveNoPathTooltip() throws {
        let image = GalleryImage(source: .file("/tmp/kept.png"), threadId: "t", agent: "Main", entryId: "e", at: "2026-10-23T10:00:00Z")
        // The masonry places a picture once its size is known; the signed URL usually brings it.
        MarkdownImages.record(CGSize(width: 800, height: 600), for: image.key)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        let view = ThreadImageGalleryView()
        view.frame = NSRect(origin: .zero, size: ThreadImageGalleryView.size)
        window.contentView!.addSubview(view)
        view.images = [image]
        view.layoutSubtreeIfNeeded()
        var all: [NSView] = []
        func walk(_ v: NSView) { all.append(v); v.subviews.forEach(walk) }
        walk(view)
        #expect(all.contains { $0.accessibilityLabel()?.hasPrefix("kept.png") == true }, "gallery tile")
        #expect(!all.contains { $0.toolTip == "/tmp/kept.png" }, "gallery grid")
        view.large = 0
        all = []; walk(view)
        #expect(!all.contains { $0.toolTip == "/tmp/kept.png" }, "gallery large picture")
    }
}
