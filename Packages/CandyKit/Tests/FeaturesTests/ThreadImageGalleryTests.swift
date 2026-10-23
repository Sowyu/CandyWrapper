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
        // The wire's shape for a dynamic tool: its output left out (WireProjection.ts:126-134).
        try item(id, thread: thread, at: at, extra: ["viewedImagePath": .string(path), "outputOmitted": .bool(true)])
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

    // MARK: Images that outlive their files

    /// The server's stored copy first, then our kept copy, then the file itself. A reply's URL has only itself.
    @Test func loadOrderPrefersTheServerThenOurCopyThenTheFile() {
        var image = GalleryImage(source: .file("/tmp/shot.png"), threadId: "t", agent: "Main", entryId: "a", at: "2026-10-23T10:00:00Z", itemId: "a")
        #expect(image.attempts == [.kept(thread: "t", item: "a"), .source])
        image.stored = ToolOutputImage(threadId: "t", itemId: "a", index: 0)
        #expect(image.attempts == [.stored(ToolOutputImage(threadId: "t", itemId: "a", index: 0)), .kept(thread: "t", item: "a"), .source])
        let url = GalleryImage(source: .url("https://x.test/c.png"), threadId: "t", agent: "Main", entryId: "m", at: "2026-10-23T10:00:00Z")
        #expect(url.attempts == [.source])
    }

    /// Dynamic tools arrive with `outputOmitted` and no image blocks, so items that viewed an image or look like captures
    /// become candidates; the server's count then gives the viewed image its stored copy and adds the rest as tiles.
    @Test func storedOutputImagesJoinTheirItems() throws {
        let p = try Self.projection("t", items: [
            try Self.viewed("a", "/tmp/shot.png", at: "2026-10-23T10:00:00Z"),
            try Self.item("b", at: "2026-10-23T10:01:00Z", extra: ["toolName": .string("browser_take_screenshot"), "outputOmitted": .bool(true)]),
            try Self.item("c", at: "2026-10-23T10:02:00Z", extra: ["toolName": .string("Bash"), "outputOmitted": .bool(true)]),
        ])
        let collected = ThreadImageGallery.collect(p, agent: "Main")
        #expect(collected.candidates.map(\.itemId) == ["a", "b"])
        let images = ThreadImageGallery.assemble(collected, counts: ["t|a": 2, "t|b": 1], hashes: ["t|a": "abc"])
        #expect(images.map(\.key) == ["media-file:/tmp/shot.png", "tool-output-image:t:a:1", "tool-output-image:t:b:0"])
        #expect(images[0].stored == ToolOutputImage(threadId: "t", itemId: "a", index: 0))
        #expect(images[0].contentHash == "abc")
        // Before the counts arrive there is only the viewed file.
        #expect(ThreadImageGallery.assemble(collected, counts: [:], hashes: [:]).count == 1)
    }

    @Test func sameContentAtTwoPathsIsOneTile() {
        var a = GalleryImage(source: .file("/tmp/a.png"), threadId: "t", agent: "Main", entryId: "a", at: "2026-10-23T10:00:00Z", itemId: "a")
        var b = GalleryImage(source: .file("/tmp/b.png"), threadId: "t", agent: "Main", entryId: "b", at: "2026-10-23T10:05:00Z", itemId: "b")
        a.contentHash = "same"; b.contentHash = "same"
        #expect(ThreadImageGallery.merge([[a, b]]).map(\.entryId) == ["b"])
        // The same path with new content, an overwritten screenshot, keeps both views.
        var c = b; c.entryId = "c"; c.contentHash = "other"; c.source = .file("/tmp/a.png")
        #expect(ThreadImageGallery.merge([[a, c]]).count == 2)
    }

    @Test func keptCopiesShareOneFilePerContentAndSurviveARelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data([0x89, 0x50, 0x4E, 0x47]) + Data(repeating: 7, count: 100)
        let cache = AgentImageCache(root: root)
        let one = await cache.store(env: "local", thread: "t", item: "a", data: png, ext: "png")
        let two = await cache.store(env: "local", thread: "t", item: "b", data: png, ext: "png")
        #expect(one == two)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("local").path)
        #expect(files == ["\(one.hash).png"])
        // A relaunch reads the index back.
        let again = AgentImageCache(root: root)
        #expect(await again.entries(env: "local", thread: "t") == ["a": one, "b": one])
        #expect(await again.url(env: "local", thread: "t", item: "a")?.lastPathComponent == "\(one.hash).png")
        // Capturing a file copies it; a missing file keeps nothing.
        let source = root.appendingPathComponent("shot.png")
        try (png + Data([1])).write(to: source)
        #expect(await again.capture(env: "local", thread: "t", item: "c", file: source) != nil)
        try FileManager.default.removeItem(at: source)
        #expect(await again.capture(env: "local", thread: "t", item: "d", file: source) == nil)
        #expect(await again.url(env: "local", thread: "t", item: "c") != nil)
    }

    @Test func keptCopiesDropLeastRecentlyViewedOverTheCapAndWithTheirThread() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        nonisolated(unsafe) var clock = 0.0
        let cache = AgentImageCache(root: root, capBytes: 250, now: { clock })
        for (i, item) in ["a", "b"].enumerated() {
            clock = Double(i)
            await cache.store(env: "local", thread: "t", item: item, data: Data(repeating: UInt8(i), count: 100), ext: "png")
        }
        clock = 5
        _ = await cache.url(env: "local", thread: "t", item: "a") // a is now the most recent
        clock = 6
        await cache.store(env: "local", thread: "u", item: "c", data: Data(repeating: 9, count: 100), ext: "png")
        #expect(await cache.entries(env: "local", thread: "t").keys.sorted() == ["a"])
        await cache.keepOnly(env: "local", threads: ["u"])
        #expect(await cache.entries(env: "local", thread: "t").isEmpty)
        #expect(await cache.entries(env: "local", thread: "u").keys.sorted() == ["c"])
        #expect(await cache.url(env: "local", thread: "u", item: "c") != nil)
    }

    static func controller(fileExists: Bool, kept: [String: String] = [:], served: Set<String> = []) -> (ThreadImageGalleryController, DitherHeaderPillView) {
        let pill = DitherHeaderPillView()
        pill.toggles = [IconName.ellipsis, .panelBottom, .panelRight].map { ToggleView(nil, icon: $0, variant: .ghost, size: .xs) }
        for t in pill.toggles { pill.addSubview(t) }
        let gallery = ThreadImageGalleryController(pill: pill)
        gallery.fileExists = { _ in fileExists }
        gallery.keptHashes = { _ in kept }
        gallery.storedCount = { _, item in served.contains(item.rawValue) ? 1 : 0 }
        gallery.keep = { _ in nil }
        return (gallery, pill)
    }

    static func settle(_ gallery: ThreadImageGalleryController, until done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(30))
    }

    /// An image nothing can load (file gone, no kept copy, no server copy) leaves the grid and the count; a file kept
    /// earlier, or whose item the server kept, stays.
    @Test func unloadableImagesLeaveTheGridAndTheCount() async throws {
        let (gallery, pill) = Self.controller(fileExists: false, kept: ["kept": "h1"], served: ["served"])
        let p = try Self.projection("t", items: [
            try Self.viewed("gone", "/tmp/gone.png", at: "2026-10-23T10:00:00Z"),
            try Self.viewed("kept", "/tmp/kept.png", at: "2026-10-23T10:01:00Z"),
            try Self.viewed("served", "/tmp/served.png", at: "2026-10-23T10:02:00Z"),
        ])
        gallery.update(threadId: "t", projection: p)
        try await Self.settle(gallery) { gallery.images.count == 2 }
        #expect(gallery.images.map(\.entryId) == ["served", "kept"])
        #expect(gallery.images.first { $0.entryId == "served" }?.stored != nil)
        #expect(gallery.images.first { $0.entryId == "kept" }?.contentHash == "h1")
        #expect(pill.galleryCount == 2)
        // A tile whose every source fails while it shows goes too.
        gallery.markFailed(gallery.images[0])
        #expect(gallery.images.map(\.entryId) == ["kept"] && pill.galleryCount == 1)
        // The card's grid and header count only what shows.
        let view = ThreadImageGalleryView()
        view.images = gallery.images
        #expect(view.images.count == 1)
    }

    /// Every image gone is the same as a thread with no images: nothing to show, a count of 0, the button hidden.
    @Test func allMissingIsAnEmptyGallery() async throws {
        let (gone, gonePill) = Self.controller(fileExists: false)
        gone.update(threadId: "t", projection: try Self.projection("t", items: [
            try Self.viewed("a", "/tmp/a.png", at: "2026-10-23T10:00:00Z"),
            try Self.viewed("b", "/tmp/b.png", at: "2026-10-23T10:01:00Z"),
        ]))
        try await Self.settle(gone) { gone.images.isEmpty }
        let (none, nonePill) = Self.controller(fileExists: false)
        none.update(threadId: "u", projection: try Self.projection("u", items: []))
        #expect(gone.images.isEmpty && none.images.isEmpty)
        for pill in [gonePill, nonePill] {
            pill.layoutSubtreeIfNeeded()
            #expect(pill.galleryCount == 0 && !pill.galleryUnseen)
            #expect(pill.gallery.isHidden)
        }
        gone.toggle()
        #expect(!gone.isOpen)
    }

    /// The same bytes reached three ways: a kept file, a tool's output image (hashed when it downloaded) and the
    /// server's copy of another viewed file. One tile, the newest view, counting all three.
    @Test func identicalBytesFromDifferentSourcesAreOneTile() {
        var kept = GalleryImage(source: .file("/tmp/a.png"), threadId: "t", agent: "Main", entryId: "a", at: "2026-10-23T10:00:00Z", itemId: "a")
        kept.contentHash = "same"
        let output = GalleryImage(source: .toolOutput(ToolOutputImage(threadId: "s", itemId: "b", index: 0)), threadId: "s",
                                  agent: "Subagent 1", entryId: "b", at: "2026-10-23T10:05:00Z", itemId: "b")
        var served = GalleryImage(source: .file("/tmp/c.png"), threadId: "t", agent: "Main", entryId: "c", at: "2026-10-23T10:02:00Z", itemId: "c")
        served.stored = ToolOutputImage(threadId: "t", itemId: "c", index: 0)
        let other = GalleryImage(source: .file("/tmp/d.png"), threadId: "t", agent: "Main", entryId: "d", at: "2026-10-23T10:03:00Z", itemId: "d")
        let loaded = [output.key: "same", served.key: "same", other.key: "different"]
        let merged = ThreadImageGallery.merge([[kept, served, other], [output]], loaded: loaded)
        #expect(merged.map(\.entryId) == ["b", "d"])
        #expect(merged[0].views == 3 && merged[0].agent == "Subagent 1")
        #expect(ThreadImageGalleryView.caption(merged[0]).hasSuffix(" · 3×"))
        #expect(ThreadImageGalleryView.caption(merged[0], long: true).hasSuffix(" · viewed 3×"))
        #expect(merged[1].views == 1 && !ThreadImageGalleryView.caption(merged[1], long: true).contains("viewed"))
        // Before the downloads answer, each source is its own tile.
        #expect(ThreadImageGallery.merge([[kept, served, other], [output]]).count == 4)
    }

    /// The card is as tall as its rows, between the empty state's minimum and the old fixed height, past which it scrolls.
    @Test func cardHeightFollowsItsRows() {
        let h = ThreadImageGalleryView.height
        let max = ThreadImageGalleryView.size.height, min = ThreadImageGalleryView.minHeight
        #expect(h(0, false) == min)
        let one = h(2, false), two = h(5, false)
        #expect(one > min && one < two && two < max)
        #expect(h(4, false) == one && h(8, false) == two)
        // A row is a tile and its caption plus the gap: 93 + 18 + 8 at 540 wide.
        #expect(two - one == 119)
        #expect(h(53, false) == max)
        #expect(h(2, true) == max)
        let view = ThreadImageGalleryView()
        view.images = Self.fakeImages().prefix(2).map { $0 }
        #expect(view.frame.height == one && view.intrinsicContentSize.height == one)
        var resized = 0
        view.onResize = { resized += 1 }
        view.images = Self.fakeImages()
        #expect(view.frame.height == h(10, false) && resized == 1)
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
