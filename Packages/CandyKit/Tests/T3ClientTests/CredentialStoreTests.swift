import Foundation
import Testing
@testable import T3Client

struct CredentialStoreTests {
    @Test func saveLoadReplaceDelete() throws {
        let store = CredentialStore(service: "dev.candywrapper.t3.test-\(UUID().uuidString)")
        let env = "test-environment"
        do {
            try store.save(token: "first", environmentId: env)
        } catch let e as CredentialStore.KeychainError {
            // A locked keychain with no GUI login can't be written. Not a code failure.
            print("keychain unavailable, skipping: \(e)")
            return
        }
        defer { try? store.delete(environmentId: env) }
        #expect(try store.load(environmentId: env) == "first")
        try store.save(token: "second", environmentId: env)
        #expect(try store.load(environmentId: env) == "second")
        try store.delete(environmentId: env)
        #expect(try store.load(environmentId: env) == nil)
        try store.delete(environmentId: env)
    }
}
