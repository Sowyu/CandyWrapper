import Foundation
import Testing
@testable import Features

/// #37116 (ChatView.logic.test.ts and composerAttachmentFiles at 4928): images dedupe by name, type, size and bytes.
struct ComposerImageDedupTests {
    private func file(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dedup-\(UUID().uuidString)-\(name)")
        try Data(bytes).write(to: url)
        return url
    }

    @Test func keepsDistinctImagesWithMatchingMetadata() throws {
        let a = try file("image.png", [1, 2, 3]), b = try file("image.png", [1, 2, 4]), c = try file("image.png", [1, 2, 3])
        defer { for u in [a, b, c] { try? FileManager.default.removeItem(at: u) } }
        let keys = [a, b, c].map { ComposerAttachmentRules.imageDedupKey(name: "image.png", mimeType: "image/png", url: $0) }
        #expect(keys[0] != keys[1])
        #expect(keys[0] == keys[2])
        // The third is a byte-for-byte repeat of the first; the second has the same name, type and size but other bytes.
        #expect(ComposerAttachmentRules.dedupedImages(keys.enumerated().map { ($0.element, $0.offset) }, existing: []) == [0, 1])
        #expect(ComposerAttachmentRules.dedupedImages([(keys[1], 0)], existing: [keys[0]]) == [0])
        #expect(ComposerAttachmentRules.dedupedImages([(keys[2], 0)], existing: [keys[0]]) == [])
    }

    @Test func anUnreadableImageMatchesNothing() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png")
        let key = ComposerAttachmentRules.imageDedupKey(name: "x.png", mimeType: "image/png", url: missing)
        #expect(key == nil)
        #expect(ComposerAttachmentRules.dedupedImages([(key, 0), (key, 1)], existing: [nil]) == [0, 1])
    }
}
