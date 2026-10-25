import Features
import Foundation
import SpaceCrypto
import SpaceLocal
import SpaceModel

/// Page images through piece 6's encrypted blob cache in the local copy. Upload is piece 16.
@MainActor
final class SpaceLocalBlobs: SpaceBlobSource {
    private let local: SpaceLocalStore
    private let keys: SpaceKeys
    /// A refused or failed attachment, with the message title and text to show. The block is never added.
    var onFailure: (String, String) -> Void = { _, _ in }

    init(local: SpaceLocalStore, keys: SpaceKeys) {
        self.local = local
        self.keys = keys
    }

    func store(_ data: Data, name: String, mime: String) async throws -> BlobReference {
        let id = keys.blobId(of: data)
        do { try await local.cacheBlob(data, id: id) }
        catch {
            let (title, text) = Self.message(for: error)
            onFailure(title, text)
            throw error
        }
        return BlobReference(id: id, name: name, mime: mime, size: Int64(data.count))
    }

    func data(for blob: BlobReference) async -> Data? {
        try? await local.cachedBlob(id: blob.id)
    }

    static func message(for error: Error) -> (String, String) {
        switch error as? SpaceLocalError {
        case .blobStorageFull?:
            return ("Space's attachment storage on this Mac is full",
                    "This attachment wasn't added. Space keeps every original on this Mac, up to 1 GB, and never deletes earlier ones to make room. Delete pages you no longer need from Trash, then try again.")
        case .blobTooLarge?:
            return ("This attachment is too large for Space", "It wasn't added. Nothing else changed.")
        default:
            return ("Space could not save this attachment", "It wasn't added, and earlier attachments are kept. Check available disk space, then reopen Space.")
        }
    }
}
