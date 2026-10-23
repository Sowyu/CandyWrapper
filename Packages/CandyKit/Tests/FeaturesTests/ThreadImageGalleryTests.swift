import AppKit
import Testing
import DesignSystem
import T3Protocol
import T3Store
@testable import Features

/// Redesign's agent image gallery: which images it collects, their order, and the toggle's dot.
@MainActor
struct ThreadImageGalleryTests {
    static func item(_ id: String, thread: String = "t", type: String = "dynamic_tool", at: String, extra: [String: JSONValue] = [:]) throws -> ProjectedTurnItem {
        var json: [String: JSONValue] = ["id": .string(id), "threadId": .string(thread), "type": .string(type), "runId": .string("r"),
                                         "ordinal": .number(1), "status": .string("completed"), "updatedAt": .string(at), "startedAt": .string(at)]
        json.merge(extra) { $1 }
        return ProjectedTurnItem(position: 0, visibility: "local", sourceThreadId: ThreadId(rawValue: thread), sourceItemId: TurnItemId(id),
                                 item: try TurnItem(json: .object(json)))
    }

    static func projection(_ thread: String, items: [ProjectedTurnItem], messages: [(String, String, String)] = []) throws -> ThreadProjection {
        let messageJSON = messages.map { id, text, at in
            #"{"id":"\#(id)","threadId":"\#(thread)","role":"assistant","text":\#(String(data: try! JSONEncoder().encode(text), encoding: .utf8)!),"streaming":false,"createdAt":"\#(at)","updatedAt":"\#(at)"}"#
        }.joined(separator: ",")
        var p = try JSONDecoder().decode(ThreadProjection.self, from: Data(#"{"thread":{"id":"\#(thread)"},"messages":[\#(messageJSON)],"updatedAt":"2026-10-23T00:00:00Z"}"#.utf8))
        p.visibleTurnItems = items
        return p
    }

    static func viewed(_ id: String, _ path: String, at: String, thread: String = "t") throws -> ProjectedTurnItem {
        try item(id, thread: thread, at: at, extra: ["viewedImagePath": .string(path)])
    }

    @Test func collectsViewedImagesToolOutputsAndReplyImages() throws {
        let output: JSONValue = .array([.object(["type": .string("image"), "data": .string("AAAA"), "mimeType": .string("image/png")]),
                                        .object(["type": .string("text"), "text": .string("done")])])
        let p = try Self.projection("t", items: [
            try Self.viewed("a", "/w/shot.png", at: "2026-10-23T10:00:00Z"),
            try Self.item("b", at: "2026-10-23T10:01:00Z", extra: ["output": output]),
            try Self.viewed("c", "/w/notes.txt", at: "2026-10-23T10:02:00Z"),
        ], messages: [("m", "Here: ![chart](https://x.test/c.png) and `code`", "2026-10-23T10:03:00Z")])
        let images = ThreadImageGallery.images(p, agent: "Main")
        #expect(images.map(\.key) == ["media-file:/w/shot.png", "tool-output-image:t:b:0", "https://x.test/c.png"])
        #expect(images.allSatisfy { $0.agent == "Main" })
        #expect(images[0].entryId == "a" && images[2].entryId == "m")
    }

    @Test func mergeIsNewestFirstAndKeepsEachPictureOnce() throws {
        let main = ThreadImageGallery.images(try Self.projection("t", items: [
            try Self.viewed("a", "/w/shot.png", at: "2026-10-23T10:00:00Z"),
            try Self.viewed("b", "/w/old.png", at: "2026-10-23T09:00:00Z"),
        ]), agent: "Main")
        // The subagent viewed the same screenshot later: one tile, the newer view, credited to the subagent.
        let child = ThreadImageGallery.images(try Self.projection("s", items: [
            try Self.viewed("x", "/w/shot.png", at: "2026-10-23T11:00:00Z", thread: "s"),
            try Self.viewed("y", "/w/sub.png", at: "2026-10-23T10:30:00Z", thread: "s"),
        ]), agent: "Subagent 1")
        let merged = ThreadImageGallery.merge([main, child])
        #expect(merged.map(\.key) == ["media-file:/w/shot.png", "media-file:/w/sub.png", "media-file:/w/old.png"])
        #expect(merged[0].agent == "Subagent 1" && merged[0].threadId == "s")
        // The child's file signs on the child's thread, so a relative path resolves in its workspace.
        #expect(merged[0].resource?["threadId"]?.stringValue == "s")
    }

    @Test func inheritedRowsBelongToTheParent() throws {
        var row = try Self.viewed("a", "/w/shot.png", at: "2026-10-23T10:00:00Z")
        row.visibility = "inherited"
        #expect(ThreadImageGallery.images(try Self.projection("t", items: [row]), agent: "Main").isEmpty)
    }

    @Test func childrenAreNumberedInStartOrderAndTasksKeepTheirTitles() {
        let names = ThreadImageGallery.agentNames([
            (id: "b", title: "", providerNative: true, createdAt: "2026-10-23T10:05:00Z"),
            (id: "t", title: "Fix the sidebar", providerNative: false, createdAt: "2026-10-23T10:00:00Z"),
            (id: "a", title: "", providerNative: true, createdAt: "2026-10-23T10:01:00Z"),
        ])
        #expect(names == ["a": "Subagent 1", "b": "Subagent 2", "t": "Fix the sidebar"])
    }

    @Test func dotCountsOnlyImagesAfterTheLastLook() throws {
        let images = ThreadImageGallery.images(try Self.projection("t", items: [
            try Self.viewed("a", "/w/1.png", at: "2026-10-23T10:00:00Z"),
            try Self.viewed("b", "/w/2.png", at: "2026-10-23T10:05:00Z"),
        ]), agent: "Main")
        let look = T3Timestamp("2026-10-23T10:01:00Z").epochMs!
        #expect(ThreadImageGallery.unseen(images, sinceMs: look) == 1)
        #expect(ThreadImageGallery.unseen(images, sinceMs: .max) == 0)
    }

    @Test func markdownImagesReadAngleBracketsAndTitles() {
        #expect(ThreadImageGallery.markdownImages(#"![a](<shots/x.png>) ![b](/y.png "t") [link](z.png)"#) == ["shots/x.png", "/y.png"])
    }

    // MARK: Offscreen renders for review, written only with GALLERY_SNAPSHOTS=<dir>.

    static func dataURI(_ hue: CGFloat, _ label: String) -> String {
        let size = NSSize(width: 320, height: 220)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1),
                       ending: NSColor(hue: hue + 0.12, saturation: 0.7, brightness: 0.35, alpha: 1))!.draw(in: rect, angle: -35)
            (label as NSString).draw(at: NSPoint(x: 18, y: 18), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.white])
            return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        return "data:image/png;base64," + png.base64EncodedString()
    }

    static func fakeImages() -> [GalleryImage] {
        let agents = ["Main", "Subagent 1", "Main", "Fix the sidebar", "Subagent 2", "Main", "Subagent 1", "Main", "Main", "Subagent 2"]
        return agents.enumerated().map { i, agent in
            GalleryImage(source: .url(dataURI(CGFloat(i) / 10, "#\(i + 1)")), threadId: "t", agent: agent, entryId: "e\(i)",
                         at: T3Timestamp(ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(-i * 190)))))
        }
    }

    static func pump(until done: () -> Bool) async {
        let end = Date().addingTimeInterval(8)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// Renders the layer tree (cached decodes come back in the snapshot's window), then puts the view back.
    static func save(_ view: NSView, _ name: String, dir: String) {
        let window = view.window
        window?.contentView = nil
        let rep = Snapshot.image(of: view, size: view.bounds.size, dark: true)
        window?.contentView = view
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir + "/" + name))
    }

    @Test func offscreenRenders() async throws {
        guard let dir = ProcessInfo.processInfo.environment["GALLERY_SNAPSHOTS"] else { return }
        let previous = ThemeRuntime.input
        defer { ThemeRuntime.apply(previous) }
        var input = ThemeRuntime.input
        input.ditherLight = true; input.ditherDark = true
        ThemeRuntime.apply(input)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let root = DSView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
        root.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
        window.contentView = root
        defer { window.contentView = nil }

        // The pill as the thread header fills it: actions, gallery (with its dot), terminal, totals, right panel.
        let pill = DitherHeaderPillView()
        pill.toggles = [IconName.ellipsis, .panelBottom, .panelRight].map { ToggleView(nil, icon: $0, variant: .ghost, size: .xs) }
        for t in pill.toggles { pill.addSubview(t) }
        pill.galleryCount = 10
        pill.galleryUnseen = true
        root.addSubview(pill)
        pill.frame = NSRect(x: 720 - 16 - pill.intrinsicContentSize.width, y: 12, width: pill.intrinsicContentSize.width, height: pill.intrinsicContentSize.height)
        root.layoutSubtreeIfNeeded()
        Self.save(root, "progress-01-button-offscreen.png", dir: dir)

        let gallery = ThreadImageGalleryView()
        gallery.canReveal = { _ in true }
        gallery.images = Self.fakeImages()
        let card = PopoverView(content: gallery, padding: .none)
        let size = card.intrinsicContentSize
        card.frame = NSRect(x: pill.frame.maxX - size.width, y: pill.frame.maxY + 6, width: size.width, height: size.height)
        root.addSubview(card)
        root.layoutSubtreeIfNeeded()
        let cells = { gallery.subviews.compactMap { $0 as? ScrollAreaView }.first?.scrollView.documentView?.subviews.compactMap { $0 as? GalleryCellView } ?? [] }
        await Self.pump { !cells().isEmpty && cells().allSatisfy { ($0.subviews.first as? AsyncImageView)?.image != nil } }
        Self.save(root, "progress-02-grid-offscreen.png", dir: dir)

        _ = gallery.handleKey(.right) // nothing: grid mode
        cells().first { $0.frame.minX > 100 }?.action?()
        root.layoutSubtreeIfNeeded()
        let picture = gallery.subviews.compactMap { $0 as? AsyncImageView }.first!
        await Self.pump { picture.loadedSide > 0 }
        Self.save(root, "progress-03-large-offscreen.png", dir: dir)
        #expect(gallery.handleKey(.escape))
    }
}
