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

    init(local: SpaceLocalStore, keys: SpaceKeys) {
        self.local = local
        self.keys = keys
    }

    func store(_ data: Data, name: String, mime: String) async throws -> BlobReference {
        let id = keys.blobId(of: data)
        try await local.cacheBlob(data, id: id)
        return BlobReference(id: id, name: name, mime: mime, size: Int64(data.count))
    }

    func data(for blob: BlobReference) async -> Data? {
        try? await local.cachedBlob(id: blob.id)
    }
}
