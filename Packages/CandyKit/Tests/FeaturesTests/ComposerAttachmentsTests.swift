import AppKit
import Foundation
import Testing
import T3Protocol
@testable import Features

/// T3's attachment and stash rules (composerAttachmentFiles.test.ts, attachmentUploadState.test.ts,
/// promptStashStore.ts, ComposerStashMenu.tsx).
@MainActor
struct ComposerAttachmentsTests {
    typealias R = ComposerAttachmentRules

    /// composerDraftStore.ts:2224-2240, 2510-2546: images upload again, finished files are checked, unfinished
    /// files come back as attach-again markers that block the send until replaced.
    @Test func draftAttachmentsSurviveARelaunchLikeT3() throws {
        let url = URL(fileURLWithPath: "/sandbox/a.png")
        let image = ComposerAttachment(id: "i", kind: .image, name: "a.png", mimeType: "image/png", sizeBytes: 3,
                                       fileURL: url, status: .ready, attachmentId: "up-i", environmentId: "env")
        let done = ComposerAttachment(id: "f", kind: .file, name: "notes.txt", mimeType: "text/plain", sizeBytes: 5,
                                      fileURL: url, status: .ready, attachmentId: "up-f", environmentId: "env")
        let halfway = ComposerAttachment(id: "h", kind: .file, name: "big.zip", mimeType: "application/zip", sizeBytes: 9,
                                         fileURL: url, status: .uploading(0.5), attachmentId: "minted", environmentId: "env")
        let records = try JSONDecoder().decode([DraftAttachmentRecord].self, from: JSONEncoder().encode(
            [image, done, halfway].map { DraftAttachmentRecord(draftKey: "draft", attachment: $0) }))
        #expect(records[0].attachmentId == nil)
        #expect(records[2].attachmentId == nil)
        #expect(records[0].restore(fileExists: { _ in false }) == nil)
        let restoredImage = try #require(records[0].restore(fileExists: { _ in true }))
        #expect(restoredImage.pending == .upload && restoredImage.attachment.attachmentId == nil)
        let restoredFile = try #require(records[1].restore(fileExists: { _ in false }))
        #expect(restoredFile.pending == .verify && restoredFile.attachment.attachmentId == "up-f" && restoredFile.attachment.status != .ready)
        let marker = try #require(records[2].restore(fileExists: { _ in true }))
        #expect(marker.pending == .reattach && marker.attachment.needsReattach)
        #expect(R.uploadBlockReason([marker.attachment]) == "Attach the interrupted file again or remove it")
        #expect(R.uploadBlockReason([marker.attachment, marker.attachment]) == "Attach the interrupted files again or remove them")
        #expect(R.matchesReattachMarker(marker.attachment, name: "big.zip", mimeType: "application/zip", sizeBytes: 9))
        #expect(!R.matchesReattachMarker(marker.attachment, name: "big.zip", mimeType: "application/zip", sizeBytes: 8))
        var video = marker.attachment; video.name = "clip.mov"; video.mimeType = ""
        #expect(R.matchesReattachMarker(video, name: "clip.mov", mimeType: "video/quicktime", sizeBytes: 9))
    }

    @Test func classifiesLikeT3() {
        #expect(R.classify(name: "a.png", mimeType: "image/png") == .image)
        #expect(R.classify(name: "photo.jpg", mimeType: "") == .image)
        #expect(R.classify(name: "photo.JPG", mimeType: "application/octet-stream") == .image)
        #expect(R.classify(name: "IMG.HEIC", mimeType: "") == .image)
        #expect(R.classify(name: "x", mimeType: "image/heif") == .image)
        #expect(R.classify(name: "a.svg", mimeType: "image/svg+xml") == .unsupportedImage)
        #expect(R.classify(name: "a.bmp", mimeType: "image/bmp") == .unsupportedImage)
        #expect(R.classify(name: "notes.txt", mimeType: "text/plain") == .file)
        #expect(R.classify(name: "clip.mov", mimeType: "video/quicktime") == .file)
        #expect(R.inferImageMimeType(name: ".png") == nil)
        #expect(R.inferImageMimeType(name: "a.webp") == "image/webp")
    }

    @Test func limitsAndMessages() {
        #expect(R.stagingLimit(capabilityKnown: false, maxUploadBytes: nil) == 50 * 1024 * 1024)
        #expect(R.stagingLimit(capabilityKnown: true, maxUploadBytes: nil) == nil)
        #expect(R.stagingLimit(capabilityKnown: true, maxUploadBytes: 100 * 1024 * 1024) == 50 * 1024 * 1024)
        #expect(R.stagingLimit(capabilityKnown: true, maxUploadBytes: 2048) == 2048)
        #expect(R.tooLargeMessage("a.zip", 50 * 1024 * 1024) == "'a.zip' exceeds the 50 MB attachment limit.")
        #expect(R.tooLargeMessage("a", 2048) == "'a' exceeds the 2 KB attachment limit.")
        #expect(R.tooLargeMessage("a", 1) == "'a' exceeds the 1 byte attachment limit.")
        #expect(R.uploadBlockReason([.ready]) == nil)
        #expect(R.uploadBlockReason([.uploading(0.5), .ready]) == "Attachment still uploading")
        #expect(R.uploadBlockReason([.uploading(0.5), .uploading(0)]) == "Attachments still uploading")
        #expect(R.uploadBlockReason([.uploading(0.5), .failed("x")]) == "Retry or remove the failed attachment")
        #expect(R.providerLimitError(Array(repeating: (false, 1), count: 101)) != nil)
        #expect(R.providerLimitError([(true, 50 * 1024 * 1024), (true, 31 * 1024 * 1024)])?.hasPrefix("Images can total up to 80 MiB") == true)
        #expect(R.providerLimitError([(false, 50 * 1024 * 1024), (false, 50 * 1024 * 1024)]) == nil)
    }

    @Test func pasteRules() {
        #expect(R.shouldHandlePaste(files: [("image.png", "image/png")], plainText: "hello"))
        #expect(!R.shouldHandlePaste(files: [("a.txt", "text/plain")], plainText: "hello"))
        #expect(R.shouldHandlePaste(files: [("a.txt", "text/plain")], plainText: ""))
        #expect(!R.shouldHandlePaste(files: [], plainText: ""))
    }

    @Test func largePastesFoldIntoFiles() {
        let big = String(repeating: "a", count: 32 * 1024)
        #expect(R.foldsPastedText(big, bypass: false, wouldExceedLimit: false))
        #expect(!R.foldsPastedText(big, bypass: true, wouldExceedLimit: true))
        #expect(!R.foldsPastedText(String(big.dropLast()), bypass: false, wouldExceedLimit: false))
        // Bytes count too: 11,000 three-byte characters are 33,000 bytes.
        #expect(R.foldsPastedText(String(repeating: "€", count: 11_000), bypass: false, wouldExceedLimit: false))
        #expect(R.foldsPastedText("short", bypass: false, wouldExceedLimit: true))
        #expect(R.pasteWouldExceedLimit(promptLength: 119_990, selectedLength: 0, textLength: 11))
        #expect(!R.pasteWouldExceedLimit(promptLength: 119_990, selectedLength: 5, textLength: 15))
        #expect(R.nextPastedTextFileName([]) == "pasted-text.txt")
        #expect(R.nextPastedTextFileName(["Pasted-Text.txt", "pasted-text-2.txt"]) == "pasted-text-3.txt")
    }

    @Test func middleTruncate() {
        #expect(R.middleTruncate("short.png") == "short.png")
        let long = "a-very-long-screenshot-name-from-yesterday.png"
        let cut = R.middleTruncate(long)
        #expect(cut.count == 36)
        #expect(cut.hasSuffix("om-yesterday.png") == false)
        #expect(cut.hasSuffix("-yesterday.png"))
        #expect(cut.contains("…"))
    }

    @Test func attachmentWireShapes() {
        var a = ComposerAttachment(id: "d1", kind: .image, name: "shot.png", mimeType: "image/png", sizeBytes: 10,
                                   fileURL: URL(fileURLWithPath: "/tmp/x.png"), environmentId: "env")
        #expect(a.chatAttachment == nil)
        #expect(a.reference == "![shot.png](t3-context://v1/image/image_d1)")
        a.status = .ready
        a.attachmentId = "up-1"
        #expect(a.chatAttachment?["id"]?.stringValue == "up-1")
        #expect(a.chatAttachment?["type"]?.stringValue == "image")
        #expect(a.contextRecord?["attachmentId"]?.stringValue == "up-1")
        #expect(a.contextRecord?["contextId"]?.stringValue == "image_d1")
        // The chip's link is a context reference the composer reads back.
        #expect(ComposerContext.referencedIds("see \(a.reference) ") == ["image_d1"])
    }

    /// Deleting an entry shrinks the open menu: its host lays it out again from `preferredHeight`.
    @Test func stashMenuAsksItsHostToResize() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let menu = ComposerStashMenuView()
        host.addSubview(menu)
        menu.entries = [PromptStashEntry(id: "1", createdAt: "", prompt: "a"), PromptStashEntry(id: "2", createdAt: "", prompt: "b")]
        let two = menu.preferredHeight()
        host.layoutSubtreeIfNeeded()
        #expect(!host.needsLayout)
        menu.entries = [PromptStashEntry(id: "1", createdAt: "", prompt: "a")]
        #expect(host.needsLayout)
        #expect(menu.preferredHeight() == two - 25)
    }

    @Test func stashSnippetAndBudget() {
        var e = PromptStashEntry(id: "1", createdAt: "2026-10-10T10:00:00.000Z", prompt: "  fix\n\n the   bug  ")
        #expect(e.snippet == "fix the bug")
        e.prompt = String(repeating: "x", count: 100)
        #expect(e.snippet == String(repeating: "x", count: 90) + "…")
        e.prompt = ""
        #expect(e.snippet == "(empty)")
        e.attachments = [.init(id: "i", name: "a.png", mimeType: "image/png", sizeBytes: 1, file: "f")]
        #expect(e.snippet == "(1 image)")
        e.files = [.init(id: "f", name: "a.txt", mimeType: "text/plain", sizeBytes: 1, attachmentId: "u", environmentId: "e")]
        #expect(e.snippet == "(2 attachments)")
        let img = { (n: String) in PromptStashEntry.Image(id: n, name: n, mimeType: "image/png", sizeBytes: 1, file: n) }
        let (kept, dropped) = PromptStashStore.partition([(img("a"), 1_300_000), (img("b"), 1_300_000), (img("c"), 200_000)])
        #expect(kept.map(\.name) == ["a", "b"])
        #expect(dropped == ["c"])
    }

    @Test func stashStoreEvictsAndSettlesOrphans() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stash-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PromptStashStore(directory: dir)
        for i in 0..<PromptStashStore.maxEntries {
            #expect(store.stash(PromptStashEntry(id: "\(i)", createdAt: "", prompt: "p\(i)")).evicted == nil)
        }
        let (evicted, written) = store.stash(PromptStashEntry(id: "new", createdAt: "", prompt: "n", pendingImageCount: 2))
        #expect(written)
        #expect(evicted?.id == "0")
        #expect(store.entries.first?.id == "new")
        #expect(store.entries.count == PromptStashStore.maxEntries)
        // A relaunch settles the images that were still encoding.
        let reopened = PromptStashStore(directory: dir)
        #expect(reopened.entries.first?.pendingImageCount == 0)
        #expect(reopened.entries.first?.unreadableImageNames == ["image 1 (not saved before reload)", "image 2 (not saved before reload)"])
        #expect(reopened.take("new").entry?.prompt == "n")
        #expect(!reopened.finalizeImages("new", images: [], dropped: [], unreadable: []))
        #expect(PromptStashStore(directory: dir).entries.count == PromptStashStore.maxEntries - 1)
    }

    @Test func imagePreparationKeepsSmallFilesAndShrinksLargeOnes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prep-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 800, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        // A gradient with a little texture: PNG stays large, JPEG gets small.
        var seed: UInt64 = 42
        func noise() -> CGFloat { seed = seed &* 6_364_136_223_846_793_005 &+ 1; return CGFloat((seed >> 33) % 32) / 255 }
        for y in 0..<800 { for x in 0..<1200 { rep.setColor(NSColor(deviceRed: CGFloat(x) / 1400 + noise(), green: CGFloat(y) / 900 + noise(), blue: 0.5, alpha: 1), atX: x, y: y) } }
        let png = dir.appendingPathComponent("noise.png")
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        let size = try png.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        let same = try await ComposerImageIO.prepare(png, name: "noise.png", mimeType: "image/png", maxBytes: size, workDir: dir)
        #expect(same.url == png)
        let small = try await ComposerImageIO.prepare(png, name: "noise.png", mimeType: "image/png", maxBytes: size / 4, workDir: dir)
        #expect(small.mimeType == "image/jpeg")
        #expect(small.name == "noise.jpg")
        #expect(small.sizeBytes <= size / 4)
        // Thumbnails decode at the asked size: the short side covers 128.
        let thumb = await ComposerImageIO.thumbnail(png, side: 128, cover: true)
        #expect(thumb.map { min($0.width, $0.height) } == 128)
    }
}
