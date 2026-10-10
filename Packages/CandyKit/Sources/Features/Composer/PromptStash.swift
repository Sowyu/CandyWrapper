import Foundation
import T3Protocol

/// One stashed prompt (`PromptStashEntry`, apps/web/src/promptStashStore.ts). Images are stored as
/// files beside the queue instead of data URLs, under the same size budget; files keep their
/// signed-upload reference and environment.
public struct PromptStashEntry: Codable, Equatable, Sendable, Identifiable {
    public struct Image: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var mimeType: String
        public var sizeBytes: Int
        /// The image's file name inside the stash directory.
        public var file: String
        public init(id: String, name: String, mimeType: String, sizeBytes: Int, file: String) {
            self.id = id; self.name = name; self.mimeType = mimeType; self.sizeBytes = sizeBytes; self.file = file
        }
    }
    /// `PersistedComposerFileAttachment`.
    public struct File: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var mimeType: String
        public var sizeBytes: Int
        public var attachmentId: String
        public var environmentId: String
        public init(id: String, name: String, mimeType: String, sizeBytes: Int, attachmentId: String, environmentId: String) {
            self.id = id; self.name = name; self.mimeType = mimeType; self.sizeBytes = sizeBytes
            self.attachmentId = attachmentId; self.environmentId = environmentId
        }
    }
    public var id: String
    /// ISO 8601.
    public var createdAt: String
    public var prompt: String
    public var attachments: [Image]
    public var files: [File]?
    /// Images over the entry's budget.
    public var droppedImageNames: [String]
    /// Images that could not be decoded or re-encoded.
    public var unreadableImageNames: [String]?
    /// Images still being encoded when the entry was written.
    public var pendingImageCount: Int?
    /// Payloads behind the prompt's context links (threads, pull requests).
    public var records: [JSONValue]?

    public init(id: String, createdAt: String, prompt: String, attachments: [Image] = [], files: [File]? = nil,
                droppedImageNames: [String] = [], unreadableImageNames: [String]? = nil, pendingImageCount: Int? = nil,
                records: [JSONValue]? = nil) {
        self.id = id; self.createdAt = createdAt; self.prompt = prompt; self.attachments = attachments; self.files = files
        self.droppedImageNames = droppedImageNames; self.unreadableImageNames = unreadableImageNames
        self.pendingImageCount = pendingImageCount; self.records = records
    }

    /// Images that did not make it into the entry, whatever the reason.
    public var missingImageCount: Int { droppedImageNames.count + (unreadableImageNames?.count ?? 0) }

    /// `stashEntrySnippet`: the prompt on one line, at most 90 characters, or an attachment count.
    public var snippet: String {
        let collapsed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if !collapsed.isEmpty {
            let chars = Array(collapsed)
            return chars.count > 90 ? String(chars.prefix(90)) + "…" : collapsed
        }
        let images = attachments.count + droppedImageNames.count, fileCount = files?.count ?? 0
        let count = images + fileCount
        if count == 0 { return "(empty)" }
        let label = images > 0 && fileCount > 0 ? "attachment" : fileCount > 0 ? "file" : "image"
        return "(\(count) \(label)\(count == 1 ? "" : "s"))"
    }
}

/// The stash queue (`usePromptStashStore`): newest first, at most 20, written at once on every
/// change. T3 keeps it in the browser's localStorage; here it is a JSON file plus the image
/// files in one directory. Last write wins across windows, like T3's tabs.
@MainActor
public final class PromptStashStore {
    /// `MAX_STASH_ENTRIES`.
    public static let maxEntries = 20
    /// `MAX_STASH_ENTRY_ATTACHMENT_CHARS`: the image budget of one entry, in data-URL characters.
    public static let maxEntryAttachmentChars = 2_700_000

    public private(set) var entries: [PromptStashEntry] = []
    public let directory: URL
    public var onChange: (() -> Void)?
    private var file: URL { directory.appendingPathComponent("prompt-stash.v2.json") }

    private struct Persisted: Codable { var version: Int; var entries: [PromptStashEntry] }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file), let persisted = try? JSONDecoder().decode(Persisted.self, from: data) {
            entries = Self.clearOrphanedPendingImages(persisted.entries)
        }
    }

    public func imageURL(_ image: PromptStashEntry.Image) -> URL { directory.appendingPathComponent(image.file) }

    /// `clearOrphanedPendingImages`: an entry still pending after a relaunch lost its images.
    static func clearOrphanedPendingImages(_ entries: [PromptStashEntry]) -> [PromptStashEntry] {
        entries.map { entry in
            guard let lost = entry.pendingImageCount, lost > 0 else { return entry }
            var e = entry
            e.pendingImageCount = 0
            e.unreadableImageNames = (e.unreadableImageNames ?? []) + (1...lost).map { "image \($0) (not saved before reload)" }
            return e
        }
    }

    /// `partitionStashAttachments`: images in order until the entry budget is spent.
    public static func partition(_ images: [(image: PromptStashEntry.Image, chars: Int)]) -> (kept: [PromptStashEntry.Image], dropped: [String]) {
        var used = 0, kept: [PromptStashEntry.Image] = [], dropped: [String] = []
        for (image, chars) in images {
            if used + chars > maxEntryAttachmentChars { dropped.append(image.name); continue }
            used += chars
            kept.append(image)
        }
        return (kept, dropped)
    }

    private func persist(_ next: [PromptStashEntry]) -> Bool {
        do {
            let data = try JSONEncoder().encode(Persisted(version: 2, entries: next))
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// `stashEntry`: prepends, evicting the oldest past the cap. Nothing changes when the write fails.
    public func stash(_ entry: PromptStashEntry) -> (evicted: PromptStashEntry?, written: Bool) {
        var next = [entry] + entries
        let evicted = next.count > Self.maxEntries ? next.removeLast() : nil
        guard persist(next) else { return (nil, false) }
        entries = next
        if let evicted { removeImages(of: evicted) }
        onChange?()
        return (evicted, true)
    }

    /// `takeEntry`: removes and returns an entry (restore and delete). The caller removes the
    /// images once it read them (`discardImages`).
    @discardableResult
    public func take(_ id: String) -> (entry: PromptStashEntry?, durable: Bool) {
        guard let entry = entries.first(where: { $0.id == id }) else { return (nil, true) }
        let next = entries.filter { $0.id != id }
        let durable = persist(next)
        entries = next
        onChange?()
        return (entry, durable)
    }

    /// `finalizeEntryImages`: the encoded images land on an entry written earlier. False when the
    /// entry is gone (restored or deleted while encoding).
    public func finalizeImages(_ id: String, images: [PromptStashEntry.Image], dropped: [String], unreadable: [String]) -> Bool {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return false }
        var next = entries
        next[i].attachments = images
        next[i].droppedImageNames = dropped
        next[i].unreadableImageNames = unreadable
        next[i].pendingImageCount = 0
        _ = persist(next)
        entries = next
        onChange?()
        return true
    }

    public func removeImages(of entry: PromptStashEntry) {
        for image in entry.attachments { try? FileManager.default.removeItem(at: imageURL(image)) }
    }
}
