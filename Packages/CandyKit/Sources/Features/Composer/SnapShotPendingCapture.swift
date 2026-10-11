import Foundation
import T3Protocol

/// A durable pending attachment keeps its destination and source through a restart.
/// DesktopSnapShot.ts persists captures until delivery; native drafts retain them until send/remove.
public struct SnapShotPendingCapture: Codable, Equatable, Sendable {
    public var draftKey: String
    public var id: String
    public var environment: String
    public var fileURL: URL
    public var name: String
    public var mimeType: String
    public var sizeBytes: Int
    public var source: JSONValue
    public init?(draftKey: String, attachment: ComposerAttachment) {
        guard let source = attachment.snapShotSource else { return nil }
        self.draftKey = draftKey; id = attachment.id; environment = attachment.environmentId
        fileURL = attachment.fileURL; name = attachment.name; mimeType = attachment.mimeType
        sizeBytes = attachment.sizeBytes; self.source = source
    }
    /// Remove local capture files only after the send succeeds.
    public static func removeDeliveredFiles(_ attachments: [ComposerAttachment]) {
        for attachment in attachments where attachment.snapShotSource != nil {
            try? FileManager.default.removeItem(at: attachment.fileURL)
        }
    }

    /// Re-upload rather than trusting a pending upload that may have expired while offline.
    public var attachment: ComposerAttachment {
        var result = ComposerAttachment(id: id, kind: .image, name: name, mimeType: mimeType,
            sizeBytes: sizeBytes, fileURL: fileURL, status: .failed("Retry upload"), environmentId: environment)
        result.snapShotSource = source
        return result
    }
}
