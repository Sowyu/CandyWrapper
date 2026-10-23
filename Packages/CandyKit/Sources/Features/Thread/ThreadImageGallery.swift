import AppKit
import DesignSystem
import T3Protocol
import T3Store

/// Redesign's image gallery: every picture the agents of a thread looked at or showed, its subagent and delegated
/// child threads included. CandyWrapper's own feature; T3 has no gallery. The images come from what the timeline
/// already draws:
/// - a tool row's viewed image (`workEntryViewedImagePath`, client-runtime/src/work-log/presentation.ts:477-493),
/// - a dynamic tool's output images (`turnItemOutputImages`, client-runtime/src/work-log/itemDetail.ts:207-221),
/// - Markdown images in assistant replies (`ChatMarkdown.tsx:1386-1400`).
public struct GalleryImage: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// A host file, as the agent wrote its path. It signs as `media-file` on its own thread, so the server resolves
        /// a relative path against that thread's workspace (apps/server/src/assets/AssetAccess.ts:509-533).
        case file(String)
        /// An http(s) or `data:` image in a reply.
        case url(String)
        /// One image of a tool's output (`tool-output-image`, contracts/src/assets.ts:44-50).
        case toolOutput(ToolOutputImage)
    }

    public var source: Source
    /// The thread whose agent saw it.
    public var threadId: ThreadId
    /// "Main", "Subagent 2" or a delegated task's title.
    public var agent: String
    /// The timeline entry that showed it: a work entry or a message id.
    public var entryId: String
    public var at: T3Timestamp
    /// The tool item that showed it, nil for a reply's image. Our kept copy is filed under it.
    public var itemId: TurnItemId?
    /// The server's stored copy of a viewed image, when the item's output kept one.
    public var stored: ToolOutputImage?
    /// The SHA-256 of our kept copy, once we have one.
    public var contentHash: String?

    public init(source: Source, threadId: ThreadId, agent: String, entryId: String, at: T3Timestamp, itemId: TurnItemId? = nil) {
        self.source = source; self.threadId = threadId; self.agent = agent; self.entryId = entryId; self.at = at; self.itemId = itemId
    }

    /// One picture however many paths or items showed it: the content when we kept a copy, else the source.
    public var dedupeKey: String { contentHash.map { "sha256:" + $0 } ?? key }

    /// Where the gallery tries to load it, in order.
    public enum Attempt: Equatable, Sendable {
        /// The server's copy (`tool-output-image`), which outlives the file.
        case stored(ToolOutputImage)
        /// Our copy, kept while the file still existed.
        case kept(thread: ThreadId, item: TurnItemId)
        /// The file, URL or tool output itself.
        case source
    }

    public var attempts: [Attempt] {
        var out: [Attempt] = []
        if let stored { out.append(.stored(stored)) }
        if case .file = source, let itemId { out.append(.kept(thread: threadId, item: itemId)) }
        out.append(.source)
        return out
    }

    /// The picture's identity: one tile per file, URL or tool output, whichever agent saw it.
    public var key: String {
        switch source {
        case .file(let path): "media-file:" + path
        case .url(let url): url
        case .toolOutput(let image): image.key
        }
    }

    /// The decode cache's key. A file an agent overwrote and viewed again, like a screenshot, gets a new view time and
    /// so new pixels.
    public var pixelKey: String { "gallery:\(key)@\(at.raw)" }

    /// The `assets.createUrl` resource for host files and tool outputs; nil for a URL that loads directly.
    public var resource: JSONValue? {
        switch source {
        case .file(let path): .object(["_tag": .string("media-file"), "threadId": .string(threadId.rawValue), "path": .string(path)])
        case .url: nil
        case .toolOutput(let image): image.resource
        }
    }

    public var filePath: String? { if case .file(let path) = source { path } else { nil } }
}

public enum ThreadImageGallery {
    /// A tool item whose stored output may hold images the stream leaves out: every `dynamic_tool` arrives with
    /// `outputOmitted` and no image blocks (apps/server/src/orchestration-v2/WireProjection.ts:126-134), while the
    /// server still serves them by item and index from the stored item (apps/server/src/assets/AssetAccess.ts:240-252,
    /// 750-768). The count comes from `orchestration.getTurnItem`, once per item.
    public struct Candidate: Hashable, Sendable {
        public var threadId: ThreadId
        public var itemId: TurnItemId
        public var entryId: String
        public var at: T3Timestamp
        public var key: String { ThreadImageGallery.itemKey(threadId, itemId) }
    }

    public struct Collected: Equatable, Sendable {
        public var images: [GalleryImage] = []
        public var candidates: [Candidate] = []
    }

    public static func itemKey(_ thread: ThreadId, _ item: TurnItemId) -> String { thread.rawValue + "|" + item.rawValue }

    /// The images of one thread's projection, oldest first.
    public static func images(_ projection: ThreadProjection, agent: String) -> [GalleryImage] {
        collect(projection, agent: agent).images
    }

    /// The images of one thread's projection, oldest first, and the tool items whose stored output may hold more:
    /// items that viewed an image, browser and computer surfaces, and tools named like screenshots.
    public static func collect(_ projection: ThreadProjection, agent: String) -> Collected {
        let thread = projection.thread.id
        var out: [GalleryImage] = []
        var candidates: [Candidate] = []
        for row in projection.visibleTurnItems {
            // Inherited rows belong to the parent thread, which collects them itself.
            guard row.visibility != "inherited" else { continue }
            // Only tool rows show images; skipping the rest keeps a push on a long thread cheap.
            guard toolTypes.contains(row.item.type) || row.item.string("viewedImagePath") != nil else { continue }
            let entry = WorkLog.entry(for: row)
            let at = row.item.startedAt ?? row.item.updatedAt
            let viewed = WorkLog.viewedImagePath(entry)
            if let path = viewed {
                out.append(GalleryImage(source: .file(path), threadId: thread, agent: agent, entryId: entry.id, at: at, itemId: row.sourceItemId))
            }
            let inline = TurnItemDetail.outputImageCount(row.item)
            for image in ToolOutputImage.list(threadId: row.sourceThreadId, itemId: row.sourceItemId, count: inline) {
                out.append(GalleryImage(source: .toolOutput(image), threadId: thread, agent: agent, entryId: entry.id, at: at, itemId: row.sourceItemId))
            }
            // Claude's Read keeps no bytes: its `{type: "image", file}` output is no block `readToolOutputImage` serves
            // (packages/shared/src/toolOutput.ts:227-238), so ingest strips it (toolOutputImageBytes.ts:105-119).
            let toolName = row.item.string("toolName") ?? ""
            if inline == 0, row.item.type == .dynamicTool, row.item.outputOmitted, toolName != "Read",
               viewed != nil || entry.toolSurface != nil || looksLikeCapture(toolName.isEmpty ? row.item.title ?? "" : toolName) {
                candidates.append(Candidate(threadId: row.sourceThreadId, itemId: row.sourceItemId, entryId: entry.id, at: at))
            }
        }
        for message in projection.messages where message.role == "assistant" && !message.streaming {
            for src in markdownImages(message.text) {
                let lower = src.lowercased()
                let source: GalleryImage.Source
                if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("data:image/") { source = .url(src) }
                else if lower.hasPrefix("file:") || src.hasPrefix("/") || !src.contains(":") { source = .file(src.hasPrefix("file://") ? String(src.dropFirst(7)) : src) }
                else { continue }
                out.append(GalleryImage(source: source, threadId: thread, agent: agent, entryId: message.id.rawValue, at: message.createdAt))
            }
        }
        return Collected(images: out, candidates: candidates)
    }

    static func looksLikeCapture(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["screenshot", "snapshot", "capture", "view_image", "viewimage"].contains { lower.contains($0) }
    }

    /// Joins what the server keeps (`counts`, by `itemKey`) and our copies' hashes (`hashes`, by `itemKey`) to the
    /// collected images. A viewed image whose item kept an output image loads that first; a candidate without a
    /// viewed image gets one tile per stored image.
    public static func assemble(_ collected: Collected, agent: String? = nil, counts: [String: Int], hashes: [String: String]) -> [GalleryImage] {
        var images = collected.images
        var viewedItems: Set<String> = []
        for i in images.indices {
            if let name = agent { images[i].agent = name }
            guard let item = images[i].itemId, case .file = images[i].source else { continue }
            let key = itemKey(images[i].threadId, item)
            viewedItems.insert(key)
            images[i].contentHash = hashes[key]
            if let n = counts[key], n > 0 { images[i].stored = ToolOutputImage(threadId: images[i].threadId, itemId: item, index: 0) }
        }
        for c in collected.candidates {
            let n = counts[c.key] ?? 0
            let first = viewedItems.contains(c.key) ? 1 : 0
            guard n > first else { continue }
            for index in first..<n {
                images.append(GalleryImage(source: .toolOutput(ToolOutputImage(threadId: c.threadId, itemId: c.itemId, index: index)),
                                           threadId: c.threadId, agent: agent ?? images.first?.agent ?? "Main", entryId: c.entryId, at: c.at, itemId: c.itemId))
            }
        }
        return images
    }

    /// The grid's tiles: missing ones only while "Show missing" is on.
    public static func visible(_ images: [GalleryImage], missing: Set<String>, showMissing: Bool) -> [GalleryImage] {
        showMissing ? images : images.filter { !missing.contains($0.pixelKey) }
    }

    /// The header's count: "53" or "53 · 41 missing".
    public static func countLabel(total: Int, missing: Int) -> String {
        missing > 0 ? "\(total) · \(missing) missing" : "\(total)"
    }

    static let toolTypes: Set<TurnItemType> = [.dynamicTool, .commandExecution, .fileSearch, .fileChange, .webSearch]

    /// `![alt](src "title")` sources, angle brackets dropped. Images inside code spans count too.
    // ponytail: a regex, not the Markdown parser; parse with MarkdownDocument if code blocks show false tiles
    static func markdownImages(_ text: String) -> [String] {
        guard text.contains("![") else { return [] }
        let pattern = #"!\[[^\]\n]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// The gallery: the open thread's images and its children's, newest first, one tile per picture (its newest view).
    public static func merge(_ lists: [[GalleryImage]]) -> [GalleryImage] {
        let all = lists.flatMap { $0 }.enumerated().sorted { a, b in
            let l = a.element.at.epochMs ?? 0, r = b.element.at.epochMs ?? 0
            return l != r ? l > r : a.offset > b.offset
        }.map(\.element)
        var seen: Set<String> = []
        return all.filter { seen.insert($0.dedupeKey).inserted }
    }

    /// Names the open thread's children: provider subagents count up in the order they started, delegated tasks keep
    /// their titles.
    public static func agentNames(_ children: [(id: ThreadId, title: String, providerNative: Bool, createdAt: T3Timestamp)]) -> [ThreadId: String] {
        var names: [ThreadId: String] = [:]
        var n = 0
        for child in children.sorted(by: { ($0.createdAt.epochMs ?? 0) < ($1.createdAt.epochMs ?? 0) }) {
            if child.providerNative { n += 1; names[child.id] = "Subagent \(n)" } else { names[child.id] = child.title.isEmpty ? "Task" : child.title }
        }
        return names
    }

    /// The button's dot: images an agent looked at after `sinceMs`, the last time the gallery closed or the thread
    /// opened this session. Opening the thread counts as seeing what it already holds.
    public static func unseen(_ images: [GalleryImage], sinceMs: Int64) -> Int {
        images.reduce(0) { $0 + (($1.at.epochMs ?? 0) > sinceMs ? 1 : 0) }
    }
}

/// Keeps the gallery's images for the open thread, the pill's toggle and dot, and the open card. Everything here runs
/// on projection pushes, child reads and load results; nothing ticks.
@MainActor
public final class ThreadImageGalleryController {
    private let pill: DitherHeaderPillView
    private var threadId: ThreadId?
    private var own = ThreadImageGallery.Collected()
    private var children: [ThreadId: ThreadImageGallery.Collected] = [:]
    private var names: [ThreadId: String] = [:]
    public private(set) var images: [GalleryImage] = []
    /// Stored output image counts and our copies' hashes, by `ThreadImageGallery.itemKey`.
    // ponytail: session only, a number and a hash per image item; drop per thread if sessions see thousands
    private var counts: [String: Int] = [:]
    private var hashes: [String: String] = [:]
    private var requested: Set<String> = []
    /// Threads whose kept copies were looked up, so a tile isn't called missing before that answer arrives.
    private var hashesLoaded: Set<ThreadId> = []
    /// Whether each tile's file existed when first checked, by pixel key. A gone file stays gone; a new view is a new tile.
    private var fileState: [String: Bool] = [:]
    /// Tiles every source failed for, by pixel key.
    private var failed: Set<String> = []
    public private(set) var missing: Set<String> = []
    public var showMissing = false { didSet { if showMissing != oldValue { sync() } } }
    /// When the gallery last closed, or the thread first opened this session, per thread.
    // ponytail: session only, one number per opened thread; persist it if the dot should survive relaunch
    private var lookedAt: [ThreadId: Int64] = [:]
    private var popup: OpenPopup?
    private weak var view: ThreadImageGalleryView?

    /// The gallery opened: read children that changed since their last read.
    public var onOpen: (() -> Void)?
    public var onOpenInThread: ((GalleryImage) -> Void)?
    public var onReveal: ((GalleryImage) -> Void)?
    public var canReveal: ((GalleryImage) -> Bool)?
    /// Whether a host file exists now: nil when it can't be told from here (a remote environment).
    public var fileExists: ((GalleryImage) -> Bool?)?
    /// Keeps a copy of a viewed file that still exists and answers with its content hash, nil when it couldn't.
    public var keep: ((GalleryImage) async -> String?)?
    /// Our kept copies of one thread: item id to content hash.
    public var keptHashes: ((ThreadId) async -> [String: String])?
    /// How many output images the server kept for an item (`orchestration.getTurnItem`), nil on failure.
    public var storedCount: ((ThreadId, TurnItemId) async -> Int?)?

    public init(pill: DitherHeaderPillView) {
        self.pill = pill
        pill.gallery.onPressedChange = { [weak self] _ in self?.toggle() }
    }

    public var isOpen: Bool { popup != nil }

    /// The open thread's own images; nil clears everything, as on a draft or Settings.
    public func update(threadId: ThreadId?, projection: ThreadProjection?) {
        if threadId != self.threadId {
            close()
            self.threadId = threadId
            children = [:]
            names = [:]
            failed = []
            showMissing = false
            if let threadId, lookedAt[threadId] == nil { lookedAt[threadId] = TimestampFormat.nowMs() }
        }
        own = projection.map { ThreadImageGallery.collect($0, agent: "Main") } ?? .init()
        sync()
        fetch(own)
    }

    /// Child threads' images as read, and every child's name.
    public func setChildren(_ collected: [ThreadId: ThreadImageGallery.Collected], names: [ThreadId: String]) {
        children = collected
        self.names = names
        sync()
        for c in collected.values { fetch(c) }
    }

    /// A tile whose every source failed.
    public func markFailed(_ image: GalleryImage) {
        guard failed.insert(image.pixelKey).inserted else { return }
        sync()
    }

    /// Asks once per item for what the server kept and keeps our own copy of viewed files, at first sight.
    private func fetch(_ collected: ThreadImageGallery.Collected) {
        for thread in Set(collected.images.map(\.threadId) + collected.candidates.map(\.threadId)) where !hashesLoaded.contains(thread) {
            guard requested.insert("hashes|" + thread.rawValue).inserted, let keptHashes else { continue }
            Task { [weak self] in
                let found = await keptHashes(thread)
                guard let self else { return }
                for (item, hash) in found { self.hashes[ThreadImageGallery.itemKey(thread, TurnItemId(item))] = hash }
                self.hashesLoaded.insert(thread)
                self.sync()
            }
        }
        for c in collected.candidates where counts[c.key] == nil {
            guard requested.insert("count|" + c.key).inserted, let storedCount else { continue }
            Task { [weak self] in
                let n = await storedCount(c.threadId, c.itemId)
                guard let self else { return }
                if let n { self.counts[c.key] = n } else { self.requested.remove("count|" + c.key) }
                self.sync()
            }
        }
        for image in collected.images {
            guard case .file = image.source, let item = image.itemId else { continue }
            let key = ThreadImageGallery.itemKey(image.threadId, item)
            guard hashes[key] == nil, requested.insert("keep|" + key).inserted, exists(image) != false, let keep else { continue }
            Task { [weak self] in
                guard let hash = await keep(image), let self else { return }
                self.hashes[key] = hash
                self.sync()
            }
        }
    }

    private func sync() {
        let lists = [ThreadImageGallery.assemble(own, counts: counts, hashes: hashes)]
            + children.map { id, c in ThreadImageGallery.assemble(c, agent: names[id] ?? "Subagent", counts: counts, hashes: hashes) }
        let next = ThreadImageGallery.merge(lists)
        if next != images { images = next }
        missing = Set(images.filter(isMissing).map(\.pixelKey))
        let shown = ThreadImageGallery.visible(images, missing: missing, showMissing: false)
        pill.galleryCount = images.count
        let since = threadId.flatMap { lookedAt[$0] } ?? .max
        pill.galleryUnseen = !isOpen && ThreadImageGallery.unseen(shown, sinceMs: since) > 0
        pill.gallery.isPressed = isOpen
        view?.apply(images: images, missing: missing, showMissing: showMissing)
    }

    /// Nothing left to load it from: every source failed, or the file is gone with no server or kept copy.
    private func isMissing(_ image: GalleryImage) -> Bool {
        if failed.contains(image.pixelKey) { return true }
        guard image.stored == nil, image.contentHash == nil, case .file = image.source else { return false }
        guard hashesLoaded.contains(image.threadId) else { return false }
        // The server's count for its item is still on its way.
        if let item = image.itemId, case let key = ThreadImageGallery.itemKey(image.threadId, item),
           requested.contains("count|" + key), counts[key] == nil { return false }
        return exists(image) == false
    }

    private func exists(_ image: GalleryImage) -> Bool? {
        if let known = fileState[image.pixelKey] { return known }
        let now = fileExists?(image)
        if let now { fileState[image.pixelKey] = now }
        return now
    }

    /// ⇧⌘I and the toggle.
    public func toggle() {
        if isOpen { close(); return }
        guard pill.window != nil, !pill.isHidden, !images.isEmpty, let window = pill.window else { pill.gallery.isPressed = false; return }
        let view = ThreadImageGalleryView()
        view.onFailed = { [weak self] image in self?.markFailed(image) }
        view.onShowMissing = { [weak self] on in self?.showMissing = on }
        view.apply(images: images, missing: missing, showMissing: showMissing)
        view.onOpenInThread = { [weak self] image in self?.close(); self?.onOpenInThread?(image) }
        view.onReveal = { [weak self] image in self?.onReveal?(image) }
        view.canReveal = { [weak self] image in self?.canReveal?(image) ?? false }
        let card = PopoverView(content: view, padding: .none)
        card.onKey = { [weak view] key in view?.handleKey(key) ?? false }
        let opened = PopupHost.host(for: window).open(card, trigger: pill.gallery, placement: PopupPlacement(side: .bottom, align: .end, sideOffset: 6),
                               motion: .popover)
        opened.onClose = { [weak self, weak opened] in
            guard let self, self.popup === opened else { return }
            self.popup = nil
            if let id = self.threadId { self.lookedAt[id] = TimestampFormat.nowMs() }
            self.sync()
        }
        popup = opened
        self.view = view
        sync()
        onOpen?()
    }

    public func close() {
        guard let popup else { return }
        guard let window = pill.window else { return }
        PopupHost.host(for: window).close(popup, returnFocus: false)
    }
}
