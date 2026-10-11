import Foundation
import ImageIO
import UniformTypeIdentifiers
import T3Protocol

/// T3's attachment rules for the composer: what counts as an image, the limits, the messages and
/// the records a sent message carries. Sources: packages/contracts/src/chatAttachment.ts,
/// apps/web/src/components/chat/composerAttachmentFiles.ts, ChatComposer.tsx `addComposerAttachments`
/// (:5762-5960), packages/client-runtime/src/state/attachments.ts and lib/attachmentUploadState.ts.
public enum ComposerAttachmentRules {
    /// `PROVIDER_SEND_TURN_MAX_ATTACHMENTS`.
    public static let maxAttachments = 100
    /// `PROVIDER_SEND_TURN_MAX_IMAGE_BYTES`: 10 MiB; larger images are re-encoded to fit.
    public static let maxImageBytes = 10 * 1024 * 1024
    /// `PROVIDER_SEND_TURN_MAX_TOTAL_IMAGE_BYTES`.
    public static let maxTotalImageBytes = 80 * 1024 * 1024
    /// `PROVIDER_SEND_TURN_MAX_FILE_BYTES`: 50 MiB.
    public static let maxFileBytes = 50 * 1024 * 1024
    /// `MAX_COMPRESSIBLE_SOURCE_BYTES`: images above this are refused before decoding.
    public static let maxCompressibleSourceBytes = 50 * 1024 * 1024
    /// `PROVIDER_SEND_TURN_SUPPORTED_IMAGE_MIME_TYPES`.
    public static let supportedImageTypes: Set<String> = ["image/gif", "image/jpeg", "image/png", "image/webp"]
    /// `ATTACHMENT_ONLY_BOOTSTRAP_PROMPT` (composerPromptHistory.ts:19): the text of a message with only attachments.
    public static let attachmentOnlyPrompt = PromptHistory.attachmentOnlyPrompt

    public enum Kind: Equatable, Sendable { case image, file, unsupportedImage }

    private static let imageTypeByExtension = ["gif": "image/gif", "jpeg": "image/jpeg", "jpg": "image/jpeg", "png": "image/png", "webp": "image/webp"]

    /// `inferImageMimeTypeFromName`.
    public static func inferImageMimeType(name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return imageTypeByExtension[name[name.index(after: dot)...].lowercased()]
    }

    /// `isHeicImageFile`: by type or by extension.
    public static func isHeic(name: String, mimeType: String) -> Bool {
        mimeType.range(of: #"^image/hei(c|f)$"#, options: [.regularExpression, .caseInsensitive]) != nil
            || name.range(of: #"\.(heic|heif)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `classifyComposerAttachmentFile`. An empty or generic type falls back to the extension.
    public static func classify(name: String, mimeType: String) -> Kind {
        let mime = mimeType.lowercased()
        if isHeic(name: name, mimeType: mime) { return .image }
        if (mime.isEmpty || mime == "application/octet-stream"), inferImageMimeType(name: name) != nil { return .image }
        guard mime.hasPrefix("image/") else { return .file }
        return supportedImageTypes.contains(mime) ? .image : .unsupportedImage
    }

    /// The MIME type a local file goes up with: its UTType's, else T3's extension guess, else octet-stream.
    public static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension
        if let mime = UTType(filenameExtension: ext)?.preferredMIMEType { return mime.lowercased() }
        return inferImageMimeType(name: url.lastPathComponent) ?? "application/octet-stream"
    }

    /// `fileAttachmentStagingLimit`: the per-file limit while the server's capabilities are known
    /// (`clampFileAttachmentUploadBytes`), the contract's 50 MiB before, nil when it takes no files.
    public static func stagingLimit(capabilityKnown: Bool, maxUploadBytes: Int?) -> Int? {
        guard capabilityKnown else { return maxFileBytes }
        return maxUploadBytes.map { min($0, maxFileBytes) }
    }

    /// `fileAttachmentTooLargeMessage`.
    public static func tooLargeMessage(_ name: String, _ limit: Int) -> String {
        let mb = 1024 * 1024
        let size = limit >= mb && limit % mb == 0 ? "\(limit / mb) MB"
            : limit >= 1024 && limit % 1024 == 0 ? "\(limit / 1024) KB" : "\(limit) \(limit == 1 ? "byte" : "bytes")"
        return "'\(name)' exceeds the \(size) attachment limit."
    }

    public static func unsupportedImageMessage(_ name: String) -> String {
        "'\(name)' is not a supported image type. Attach GIF, HEIC, HEIF, JPEG, PNG, or WebP images."
    }
    public static let countMessage = "You can attach up to \(maxAttachments) files per message."

    /// `PROVIDER_SEND_TURN_MAX_INPUT_CHARS`.
    public static let maxInputChars = 120_000
    /// `PASTED_TEXT_ATTACHMENT_THRESHOLD_BYTES`.
    public static let pastedTextThresholdBytes = 32 * 1024

    /// `pastedTextDisposition`: true when a paste becomes a text file (32 KiB, by length or UTF-8 bytes,
    /// or too long for the message), unless Cmd+Shift+V asked for it inline.
    public static func foldsPastedText(_ text: String, bypass: Bool, wouldExceedLimit: Bool) -> Bool {
        if bypass || text.isEmpty { return false }
        return wouldExceedLimit || text.utf16.count >= pastedTextThresholdBytes || text.utf8.count >= pastedTextThresholdBytes
    }

    /// `wouldTextPasteExceedLimit` in UTF-16 units, like JavaScript string lengths.
    public static func pasteWouldExceedLimit(promptLength: Int, selectedLength: Int, textLength: Int) -> Bool {
        promptLength - selectedLength + textLength > maxInputChars
    }

    /// `nextPastedTextFileName`: `pasted-text.txt`, then `pasted-text-2.txt` and on.
    public static func nextPastedTextFileName(_ existing: [String]) -> String {
        let names = Set(existing.map { $0.lowercased() })
        if !names.contains("pasted-text.txt") { return "pasted-text.txt" }
        var n = 2
        while names.contains("pasted-text-\(n).txt") { n += 1 }
        return "pasted-text-\(n).txt"
    }

    /// `attachmentUploadBlockReason`: why the send waits (the send button's tooltip).
    public static func uploadBlockReason(_ statuses: [ComposerFileRow.Status]) -> String? {
        var pending = 0, failed = 0
        for status in statuses {
            switch status {
            case .failed: failed += 1
            case .uploading: pending += 1
            case .ready: break
            }
        }
        if failed > 0 { return failed == 1 ? "Retry or remove the failed attachment" : "Retry or remove the failed attachments" }
        if pending > 0 { return pending == 1 ? "Attachment still uploading" : "Attachments still uploading" }
        return nil
    }

    /// `getProviderAttachmentLimitError`.
    public static func providerLimitError(_ attachments: [(isImage: Bool, sizeBytes: Int)]) -> String? {
        if attachments.count > maxAttachments { return "You can attach up to \(maxAttachments) files per message or question response." }
        let imageBytes = attachments.reduce(0) { $0 + ($1.isImage ? $1.sizeBytes : 0) }
        if imageBytes > maxTotalImageBytes {
            return "Images can total up to 80 MiB per message or question response. Use smaller images or send fewer at once."
        }
        return nil
    }

    /// `shouldHandleComposerAttachmentPaste`: images always win; other files only when the paste has no text.
    public static func shouldHandlePaste(files: [(name: String, mimeType: String)], plainText: String) -> Bool {
        if files.contains(where: { classify(name: $0.name, mimeType: $0.mimeType) != .file }) { return true }
        if !plainText.isEmpty { return false }
        return !files.isEmpty
    }

    /// `middleTruncateAttachmentName` (composerInlineChip.ts:4-14).
    public static func middleTruncate(_ name: String, max: Int = 36) -> String {
        let chars = Array(name)
        guard chars.count > max else { return name }
        if max <= 0 { return "" }
        if max == 1 { return "…" }
        let available = max - 1
        let suffixLength = min(available - 1, available >= 18 ? 14 : (available + 1) / 2)
        let prefixLength = available - suffixLength
        return String(chars.prefix(prefixLength)) + "…" + (suffixLength == 0 ? "" : String(chars.suffix(suffixLength)))
    }
}

/// One file or image in a draft (`ComposerImageAttachment`, `ComposerFileAttachment`). Its bytes
/// stay on disk at `fileURL` (a temporary copy for pasted data), never in memory.
public struct ComposerAttachment: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case image, file }
    /// The draft id; the chip's context id derives from it.
    public var id: String
    public var kind: Kind
    public var name: String
    public var mimeType: String
    public var sizeBytes: Int
    public var fileURL: URL
    public var status: ComposerFileRow.Status
    /// The pending upload the server minted; the attachment's id on the wire.
    public var attachmentId: String?
    /// The environment that holds the upload.
    public var environmentId: String
    /// Clipboard text folded into a file (`PastedTextAttachmentSource`).
    public var pastedText = false
    public var snapShotSource: JSONValue?

    public init(id: String = UUID().uuidString.lowercased(), kind: Kind, name: String, mimeType: String, sizeBytes: Int,
                fileURL: URL, status: ComposerFileRow.Status = .uploading(0), attachmentId: String? = nil, environmentId: String) {
        self.id = id; self.kind = kind; self.name = name; self.mimeType = mimeType; self.sizeBytes = sizeBytes
        self.fileURL = fileURL; self.status = status; self.attachmentId = attachmentId; self.environmentId = environmentId
    }

    /// `toKindScopedComposerContextId(type, id)`.
    public var contextId: String { ComposerContext.kindScopedId(kind.rawValue, id) }
    /// `imageContextReference` / `fileContextReference` as prompt text: `![name](…)` or `[name](…)`.
    public var reference: String {
        ComposerContext.reference(ComposerContext.Reference(kind: kind.rawValue, contextId: contextId, label: name))
    }

    /// `ChatImageAttachment` / `ChatFileAttachment` once uploaded.
    public var chatAttachment: JSONValue? {
        guard status == .ready, let attachmentId else { return nil }
        var fields: [String: JSONValue] = ["type": .string(kind.rawValue), "id": .string(attachmentId), "name": .string(name),
                                           "mimeType": .string(mimeType), "sizeBytes": .number(Double(sizeBytes))]
        if let snapShotSource { fields["source"] = snapShotSource }
        if pastedText { fields["source"] = .object(["_tag": .string("pasted-text")]) }
        return .object(fields)
    }

    /// `attachmentContextRecord` bound to the uploaded id.
    public var contextRecord: JSONValue? {
        guard let attachmentId else { return nil }
        return .object(["version": .number(1), "kind": .string(kind.rawValue), "contextId": .string(contextId),
                        "label": .string(ComposerContext.sanitizeLabel(name, kind: kind.rawValue)), "attachmentId": .string(attachmentId),
                        "name": .string(name), "mimeType": .string(mimeType), "sizeBytes": .number(Double(sizeBytes))])
    }

    public var row: ComposerFileRow { ComposerFileRow(id: id, name: name, sizeBytes: sizeBytes, status: status) }
}

/// Image decoding and re-encoding with ImageIO, always off the main thread. Thumbnails decode at
/// the size they are drawn (`CGImageSourceCreateThumbnailAtIndex`), so a 40 MP photo never sits
/// in memory at full size.
public enum ComposerImageIO {
    /// `MAX_DIMENSION` for re-encoded images.
    static let maxDimension: CGFloat = 2048
    /// `QUALITY_STEPS`, then `FALLBACK_SCALE_STEPS`.
    static let qualitySteps: [CGFloat] = [0.92, 0.85, 0.78, 0.68]
    static let fallbackScales: [CGFloat] = [0.75, 0.55]
    /// `MAX_STASH_IMAGE_DATA_URL_CHARS`.
    public static let maxStashImageDataURLChars = 1_300_000

    /// Pixel size without decoding.
    public static func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// A thumbnail whose shorter side covers `side` pixels (`object-cover`), or whose longer side
    /// fits `side` when `cover` is false. Orientation applied.
    public static func thumbnail(_ url: URL, side: Int, cover: Bool) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            var maxPixel = side
            if cover, let size = pixelSize(url), size.width > 0, size.height > 0 {
                let ratio = max(size.width, size.height) / min(size.width, size.height)
                maxPixel = Int((CGFloat(side) * ratio).rounded(.up))
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }

    public enum PrepareFailure: Error, Equatable { case tooLarge, unreadable }

    /// `prepareImageForAttachment`: HEIC and HEIF become JPEG; an image over `maxBytes` is
    /// re-encoded down the quality ladder, then at smaller scales. Files within the limit pass
    /// through byte for byte. Returns the file to upload, its name and type.
    public static func prepare(_ url: URL, name: String, mimeType: String, maxBytes: Int, workDir: URL) async throws
        -> (url: URL, name: String, mimeType: String, sizeBytes: Int)
    {
        try await Task.detached(priority: .userInitiated) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let heic = ComposerAttachmentRules.isHeic(name: name, mimeType: mimeType)
            if !heic, size <= maxBytes { return (url, name, mimeType, size) }
            if size > ComposerAttachmentRules.maxCompressibleSourceBytes { throw PrepareFailure.tooLarge }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw PrepareFailure.unreadable }
            // ponytail: re-encodes to JPEG (T3 prefers WebP, which ImageIO cannot write); transparency is lost on oversized PNGs
            let base = (name as NSString).deletingPathExtension.isEmpty ? "image" : (name as NSString).deletingPathExtension
            let outName = base + ".jpg"
            let out = workDir.appendingPathComponent(UUID().uuidString + ".jpg")
            guard let pixels = pixelSize(url) else { throw PrepareFailure.unreadable }
            let longSide = max(pixels.width, pixels.height)
            // A HEIC first converts at full size and the first quality (`heicTo`); anything still
            // over the limit walks the ladder at `MAX_DIMENSION` and below.
            var passes: [(side: CGFloat, qualities: [CGFloat])] = heic ? [(longSide, [qualitySteps[0]])] : []
            passes += ([1] + fallbackScales).map { (min(longSide, maxDimension) * $0, qualitySteps) }
            for (side, qualities) in passes {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, Int(side)),
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw PrepareFailure.unreadable }
                for quality in qualities {
                    guard let data = encodeJPEG(image, quality: quality) else { throw PrepareFailure.unreadable }
                    if data.count <= maxBytes {
                        try data.write(to: out)
                        return (out, outName, "image/jpeg", data.count)
                    }
                }
            }
            throw PrepareFailure.tooLarge
        }.value
    }

    static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// A data URL's length for `bytes` of `mimeType` (`data:<type>;base64,` plus base64).
    public static func dataURLChars(bytes: Int, mimeType: String) -> Int { "data:\(mimeType);base64,".count + (bytes + 2) / 3 * 4 }

    /// `compressImageForStash`: the image as stored in the stash, within `maxStashImageDataURLChars`.
    /// Returns nil with `tooLarge` or `unreadable` like T3.
    public static func stashCopy(_ url: URL, mimeType: String, to out: URL) async -> Result<(mimeType: String, bytes: Int), PrepareFailure> {
        await Task.detached(priority: .utility) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if dataURLChars(bytes: size, mimeType: mimeType) <= maxStashImageDataURLChars {
                do { try FileManager.default.copyItem(at: url, to: out) } catch { return .failure(.unreadable) }
                return .success((mimeType, size))
            }
            if size > ComposerAttachmentRules.maxCompressibleSourceBytes { return .failure(.tooLarge) }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return .failure(.unreadable) }
            let long = pixelSize(url).map { max($0.width, $0.height) } ?? maxDimension
            for scale in [1] + fallbackScales {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, Int(min(long, maxDimension) * scale)),
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return .failure(.unreadable) }
                for quality in qualitySteps {
                    guard let data = encodeJPEG(image, quality: quality) else { return .failure(.unreadable) }
                    if dataURLChars(bytes: data.count, mimeType: "image/jpeg") <= maxStashImageDataURLChars {
                        do { try data.write(to: out) } catch { return .failure(.unreadable) }
                        return .success(("image/jpeg", data.count))
                    }
                }
            }
            return .failure(.tooLarge)
        }.value
    }
}
