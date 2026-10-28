import AppKit
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

    /// `isDngFile` (composerAttachmentFiles.ts:62-70): DNG originals attach as plain files (14b828e58e).
    public static func isDng(name: String, mimeType: String) -> Bool {
        let mime = mimeType.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return name.lowercased().hasSuffix(".dng") || ["image/dng", "image/x-dng", "image/x-adobe-dng"].contains(mime)
    }

    /// T3 3814, shared/image.ts and composerAttachmentFiles.ts:77-86: SVG bytes stay files.
    public static func isSvg(name: String, mimeType: String) -> Bool {
        name.lowercased().hasSuffix(".svg") || mimeType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased() == "image/svg+xml"
    }

    public static func fileMimeType(name: String, mimeType: String) -> String {
        if isSvg(name: name, mimeType: mimeType) { return "image/svg+xml" }
        if isDng(name: name, mimeType: mimeType) { return "image/x-adobe-dng" }
        return mimeType.isEmpty ? "application/octet-stream" : mimeType
    }

    /// `classifyComposerAttachmentFile`. An empty or generic type falls back to the extension.
    public static func classify(name: String, mimeType: String) -> Kind {
        let mime = mimeType.lowercased()
        if isSvg(name: name, mimeType: mime) || isDng(name: name, mimeType: mime) { return .file }
        if isHeic(name: name, mimeType: mime) { return .image }
        if (mime.isEmpty || mime == "application/octet-stream"), inferImageMimeType(name: name) != nil { return .image }
        guard mime.hasPrefix("image/") else { return .file }
        return supportedImageTypes.contains(mime) ? .image : .unsupportedImage
    }

    /// The MIME type a local file goes up with: its UTType's, else T3's extension guess, else octet-stream.
    public static func mimeType(for url: URL) -> String {
        // `composerFileAttachmentMimeType`: a DNG goes up as `image/x-adobe-dng` (composerAttachmentFiles.ts:72-75).
        if isSvg(name: url.lastPathComponent, mimeType: "") { return "image/svg+xml" }
        if isDng(name: url.lastPathComponent, mimeType: "") { return "image/x-adobe-dng" }
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

    /// The send button's tooltip for a draft's attachments: files that lost their upload across a relaunch
    /// first (ChatComposer.tsx:1964-1981), then `attachmentUploadBlockReason`.
    public static func uploadBlockReason(_ attachments: [ComposerAttachment]) -> String? {
        let reattach = attachments.filter(\.needsReattach).count
        if reattach > 0 {
            return reattach == 1 ? "Attach the interrupted file again or remove it" : "Attach the interrupted files again or remove them"
        }
        return uploadBlockReason(attachments.map(\.status))
    }

    /// The failed uploads a send starts again (`retryAttachmentUpload`, ChatView.tsx:6438-6446).
    public static func retryableFailures(_ attachments: [ComposerAttachment]) -> [ComposerAttachment] {
        attachments.filter { a in
            if case .failed = a.status { return !a.needsReattach }
            return false
        }
    }

    /// `composerFileMatchesReattachMarker` (composerDraftStore.ts:906-917): same name and size, and the same
    /// type unless the marker's was empty or generic and both are videos.
    public static func matchesReattachMarker(_ marker: ComposerAttachment, name: String, mimeType: String, sizeBytes: Int) -> Bool {
        guard marker.name == name, marker.sizeBytes == sizeBytes else { return false }
        if marker.mimeType == mimeType { return true }
        // DNGs match by their normalized type (composerDraftStore.ts:784-793).
        if isSvg(name: marker.name, mimeType: marker.mimeType), isSvg(name: name, mimeType: mimeType) { return true }
        if isDng(name: marker.name, mimeType: marker.mimeType), isDng(name: name, mimeType: mimeType) { return true }
        let markerType = marker.mimeType.lowercased()
        func isVideo(_ name: String, _ type: String) -> Bool {
            type.lowercased().hasPrefix("video/")
                || UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .movie) == true
        }
        return (markerType.isEmpty || markerType == "application/octet-stream") && isVideo(marker.name, markerType) && isVideo(name, mimeType)
    }

    /// `attachmentUploadBlockReason` (lib/attachmentUploadState.ts:29-49): why the send waits (the send
    /// button's tooltip). Send retries failed uploads, so they don't block it (073734c1e9).
    public static func uploadBlockReason(_ statuses: [ComposerFileRow.Status]) -> String? {
        var pending = 0
        for status in statuses {
            if case .uploading = status { pending += 1 }
        }
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
        if files.contains(where: { isDng(name: $0.name, mimeType: $0.mimeType) || isSvg(name: $0.name, mimeType: $0.mimeType) || classify(name: $0.name, mimeType: $0.mimeType) != .file }) { return true }
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
    /// A file whose upload did not survive a relaunch (`composerFileNeedsReattach`): no server copy,
    /// so its chip asks for the file again and the send waits.
    public var needsReattach = false

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
    /// `IMAGE_ATTACHMENT_MAX_EDGE` (client-runtime imageAttachmentSize.ts, adb04202b): the longest edge a
    /// PNG or JPEG attachment keeps, and `MAX_DIMENSION` for re-encoded images. Anthropic rejects an image
    /// over 2000 px on a side once a request holds more than 20 images, so one large paste broke every
    /// later Claude request in its thread.
    static let maxDimension: CGFloat = 2000
    /// `QUALITY_STEPS`, then `FALLBACK_SCALE_STEPS`.
    static let qualitySteps: [CGFloat] = [0.92, 0.85, 0.78, 0.68]
    static let fallbackScales: [CGFloat] = [0.75, 0.55]
    /// `MAX_STASH_IMAGE_DATA_URL_CHARS`.
    public static let maxStashImageDataURLChars = 1_300_000

    /// `downscalableImageMimeType`: the formats re-encoded in place. GIF, WebP and SVG stay as attached.
    static func downscalableType(_ mimeType: String) -> UTType? {
        switch mimeType.lowercased() {
        case "image/png": .png
        case "image/jpeg", "image/jpg": .jpeg
        default: nil
        }
    }

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
    public static func thumbnail(_ url: URL, side: Int, cover: Bool, measurementKey: String? = nil) async -> CGImage? {
        let decoded = await ImageDecodeWorker.shared.run { () -> (image: CGImage, natural: CGSize)? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0 else { return nil }
            let rotated = (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
            let natural = rotated ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
            let ratio = cover ? CGFloat(max(w, h)) / CGFloat(min(w, h)) : 1
            let maxPixel = Int(min(4096, (CGFloat(max(1, side)) * ratio).rounded(.up)))
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            let start = ContinuousClock.now
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            ImageTiming.mark("decode", "\(url.lastPathComponent) \(maxPixel) took \(ContinuousClock.now - start)")
            return (image, natural)
        }
        guard !Task.isCancelled else { return nil }
        guard let decoded else {
            // NSImage renders SVG natively; ImageIO has no SVG source decoder. Keep the ordinary
            // file icon when the SVG is invalid (FileContextChip at 3814).
            let data = await ImageDecodeWorker.shared.run { try? Data(contentsOf: url, options: .mappedIfSafe) }
            guard !Task.isCancelled, let data, data.count <= ComposerAttachmentRules.maxFileBytes else { return nil }
            return await MainActor.run {
                guard let image = NSImage(data: data), image.isValid else { return nil }
                let size = image.size
                guard size.width > 0, size.height > 0 else { return nil }
                let scale = CGFloat(min(4096, max(1, side))) / (cover ? min(size.width, size.height) : max(size.width, size.height))
                let output = NSImage(size: CGSize(width: min(4096, size.width * scale), height: min(4096, size.height * scale)))
                output.lockFocus()
                image.draw(in: NSRect(origin: .zero, size: output.size))
                output.unlockFocus()
                return output.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        }
        // Keep the source's exact aspect ratio across differently rounded thumbnail sizes.
        if let measurementKey { await MarkdownImages.record(decoded.natural, for: measurementKey) }
        return decoded.image
    }

    public enum PrepareFailure: Error, Equatable { case tooLarge, unreadable }

    /// `prepareImageForAttachment`: HEIC and HEIF become JPEG. A PNG or JPEG longer than `maxDimension`
    /// is scaled to it in its own format, so a PNG keeps its transparency (`fitImageToMaxEdge`). An image
    /// still over `maxBytes` is re-encoded down the quality ladder, then at smaller scales. Other files
    /// within the limit pass through byte for byte. Returns the file to upload, its name and type.
    public static func prepare(_ url: URL, name: String, mimeType: String, maxBytes: Int, workDir: URL) async throws
        -> (url: URL, name: String, mimeType: String, sizeBytes: Int)
    {
        try await Task.detached(priority: .userInitiated) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let heic = ComposerAttachmentRules.isHeic(name: name, mimeType: mimeType)
            let fitType: UTType? = heic ? .jpeg : downscalableType(mimeType)
            let pixels = pixelSize(url)
            let longSide = pixels.map { max($0.width, $0.height) }
            let oversized = fitType != nil && (longSide ?? 0) > maxDimension
            if !heic, !oversized, size <= maxBytes { return (url, name, mimeType, size) }
            if size > ComposerAttachmentRules.maxCompressibleSourceBytes { throw PrepareFailure.tooLarge }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let longSide else { throw PrepareFailure.unreadable }
            let base = (name as NSString).deletingPathExtension.isEmpty ? "image" : (name as NSString).deletingPathExtension
            func image(side: CGFloat) throws -> CGImage {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, Int(side)),
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw PrepareFailure.unreadable }
                return image
            }
            // A HEIC converts at the first quality (`heicTo`), then fits the edge like any JPEG; a PNG or JPEG
            // over the edge is scaled in its own format.
            if let fitType, heic || oversized {
                let fitted = try image(side: min(longSide, maxDimension))
                guard let data = encode(fitted, type: fitType, quality: qualitySteps[0]) else { throw PrepareFailure.unreadable }
                if data.count <= maxBytes {
                    let ext = fitType == .png ? "png" : "jpg"
                    let out = workDir.appendingPathComponent(UUID().uuidString + "." + ext)
                    try data.write(to: out)
                    return (out, heic ? base + ".jpg" : name, fitType.preferredMIMEType ?? mimeType, data.count)
                }
            }
            // ponytail: re-encodes to JPEG (T3 prefers WebP, which ImageIO cannot write); transparency is lost on oversized PNGs
            let outName = base + ".jpg"
            let out = workDir.appendingPathComponent(UUID().uuidString + ".jpg")
            for scale in [1] + fallbackScales {
                let scaled = try image(side: min(longSide, maxDimension) * scale)
                for quality in qualitySteps {
                    guard let data = encodeJPEG(scaled, quality: quality) else { throw PrepareFailure.unreadable }
                    if data.count <= maxBytes {
                        try data.write(to: out)
                        return (out, outName, "image/jpeg", data.count)
                    }
                }
            }
            throw PrepareFailure.tooLarge
        }.value
    }

    static func encode(_ image: CGImage, type: UTType, quality: CGFloat) -> Data? {
        if type == .jpeg { return encodeJPEG(image, quality: quality) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
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
