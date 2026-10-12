import Foundation
import T3Protocol

/// One draft attachment as it survives a relaunch, like T3's `t3code:composer-drafts:v1`
/// (`PersistedComposerImageAttachment` and `PersistedComposerDraftFileAttachment`, composerDraftStore.ts:138-145,
/// 193-220, 2224-2240). An image keeps its bytes, here a copy the app owns, and uploads again. A file keeps only a
/// finished upload, which is checked against the server (`verifyPersistedAttachmentUpload`); a file whose upload
/// never finished comes back as a marker that asks for the file again (`composerFileNeedsReattach`).
public struct DraftAttachmentRecord: Codable, Equatable, Sendable {
    public var draftKey: String
    public var id: String
    public var kind: String
    public var environment: String
    public var name: String
    public var mimeType: String
    public var sizeBytes: Int
    public var fileURL: URL
    /// A file's finished upload.
    public var attachmentId: String?
    public var pastedText: Bool?
    public var source: JSONValue?

    public init(draftKey: String, attachment a: ComposerAttachment) {
        self.draftKey = draftKey; id = a.id; kind = a.kind.rawValue; environment = a.environmentId
        name = a.name; mimeType = a.mimeType; sizeBytes = a.sizeBytes; fileURL = a.fileURL
        attachmentId = a.kind == .file && a.status == .ready && !a.needsReattach ? a.attachmentId : nil
        pastedText = a.pastedText ? true : nil
        source = a.snapShotSource
    }

    /// A SnapShot capture saved by an older build (`snapShotPending.v1`).
    public init(capture: SnapShotPendingCapture) {
        draftKey = capture.draftKey; id = capture.id; kind = ComposerAttachment.Kind.image.rawValue; environment = capture.environment
        name = capture.name; mimeType = capture.mimeType; sizeBytes = capture.sizeBytes; fileURL = capture.fileURL
        source = capture.source
    }

    /// What a restored attachment needs once its environment connects.
    public enum Pending: Equatable, Sendable {
        /// Upload the image's bytes again.
        case upload
        /// Ask the server whether the file's upload still exists.
        case verify
        /// Nothing: the file must be attached again.
        case reattach
    }

    /// The attachment to put back in its draft, or nil for an image whose bytes are gone (T3 drops an image
    /// that fails to hydrate, `hydrateImagesFromPersisted`).
    public func restore(fileExists: (URL) -> Bool) -> (attachment: ComposerAttachment, pending: Pending)? {
        let kind = ComposerAttachment.Kind(rawValue: kind) ?? .file
        var a = ComposerAttachment(id: id, kind: kind, name: name, mimeType: mimeType, sizeBytes: sizeBytes,
                                   fileURL: fileURL, status: .uploading(0), environmentId: environment)
        a.pastedText = pastedText ?? false
        a.snapShotSource = source
        if kind == .image { return fileExists(fileURL) ? (a, .upload) : nil }
        if let attachmentId {
            a.attachmentId = attachmentId
            return (a, .verify)
        }
        a.needsReattach = true
        a.status = .failed("Attach the file again")
        return (a, .reattach)
    }
}
