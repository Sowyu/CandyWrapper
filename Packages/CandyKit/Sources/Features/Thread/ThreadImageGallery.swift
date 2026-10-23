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

    public init(source: Source, threadId: ThreadId, agent: String, entryId: String, at: T3Timestamp) {
        self.source = source; self.threadId = threadId; self.agent = agent; self.entryId = entryId; self.at = at
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
    /// The images of one thread's projection, oldest first.
    public static func images(_ projection: ThreadProjection, agent: String) -> [GalleryImage] {
        let thread = projection.thread.id
        var out: [GalleryImage] = []
        for row in projection.visibleTurnItems {
            // Inherited rows belong to the parent thread, which collects them itself.
            guard row.visibility != "inherited" else { continue }
            // Only tool rows show images; skipping the rest keeps a push on a long thread cheap.
            guard toolTypes.contains(row.item.type) || row.item.string("viewedImagePath") != nil else { continue }
            let entry = WorkLog.entry(for: row)
            let at = row.item.startedAt ?? row.item.updatedAt
            if let path = WorkLog.viewedImagePath(entry) {
                out.append(GalleryImage(source: .file(path), threadId: thread, agent: agent, entryId: entry.id, at: at))
            }
            for image in ToolOutputImage.list(threadId: row.sourceThreadId, itemId: row.sourceItemId, count: TurnItemDetail.outputImageCount(row.item)) {
                out.append(GalleryImage(source: .toolOutput(image), threadId: thread, agent: agent, entryId: entry.id, at: at))
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
        return out
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
        return all.filter { seen.insert($0.key).inserted }
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
/// on projection pushes and child reads; nothing ticks.
@MainActor
public final class ThreadImageGalleryController {
    private let pill: DitherHeaderPillView
    private var threadId: ThreadId?
    private var own: [GalleryImage] = []
    private var children: [ThreadId: [GalleryImage]] = [:]
    private var names: [ThreadId: String] = [:]
    public private(set) var images: [GalleryImage] = []
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
            if let threadId, lookedAt[threadId] == nil { lookedAt[threadId] = TimestampFormat.nowMs() }
        }
        own = projection.map { ThreadImageGallery.images($0, agent: "Main") } ?? []
        sync()
    }

    /// Child threads' images as read, and every child's name.
    public func setChildren(_ images: [ThreadId: [GalleryImage]], names: [ThreadId: String]) {
        children = images
        self.names = names
        sync()
    }

    private func sync() {
        let named = children.map { id, list in list.map { var image = $0; image.agent = names[id] ?? "Subagent"; return image } }
        let next = ThreadImageGallery.merge([own] + named)
        if next != images { images = next }
        pill.galleryCount = images.count
        let since = threadId.flatMap { lookedAt[$0] } ?? .max
        pill.galleryUnseen = !isOpen && ThreadImageGallery.unseen(images, sinceMs: since) > 0
        pill.gallery.isPressed = isOpen
        view?.images = images
    }

    /// ⇧⌘I and the toggle.
    public func toggle() {
        if isOpen { close(); return }
        guard pill.window != nil, !pill.isHidden, !images.isEmpty, let window = pill.window else { pill.gallery.isPressed = false; return }
        let view = ThreadImageGalleryView()
        view.images = images
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
